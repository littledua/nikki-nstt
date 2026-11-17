-- Lưu tủ đồ, bộ đã lưu và Tích KC theo ID + mã PIN (không cần email).
-- Chạy 1 lần trong Supabase › SQL Editor (dán cả file rồi bấm Run). Chạy lại cũng không sao.
--
-- Bảng không mở cho ai đọc thẳng: web chỉ gọi được 2 hàm so_tay_mo / so_tay_luu,
-- hàm tự kiểm tra mã PIN (lưu dạng băm bcrypt, không lưu PIN thật).
-- Sai PIN 10 lần liền thì ID đó bị khóa 15 phút.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.so_tay (
  ma text primary key check (ma ~ '^[a-z0-9_.-]{3,32}$'),
  pin_hash text not null,
  du_lieu jsonb not null default '{}'::jsonb,
  sai int not null default 0,
  khoa_den timestamptz,
  tao_luc timestamptz not null default now(),
  sua_luc timestamptz not null default now()
);
alter table public.so_tay enable row level security;  -- không có policy: chỉ đi qua 2 hàm bên dưới
revoke all on public.so_tay from anon, authenticated;

-- Kiểm tra ID + PIN. Trả: ok | chua_co | khoa | sai_pin | ma | pin
create or replace function public.so_tay_kt(k text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare r public.so_tay;
begin
  if k !~ '^[a-z0-9_.-]{3,32}$' then return 'ma'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4,8}$' then return 'pin'; end if;
  select * into r from public.so_tay where ma = k for update;
  if not found then return 'chua_co'; end if;
  if r.khoa_den is not null and r.khoa_den > now() then return 'khoa'; end if;
  if r.pin_hash <> crypt(p_pin, r.pin_hash) then
    update public.so_tay set
      sai = case when sai + 1 >= 10 then 0 else sai + 1 end,
      khoa_den = case when sai + 1 >= 10 then now() + interval '15 minutes' else khoa_den end
    where ma = k;
    return 'sai_pin';
  end if;
  if r.sai <> 0 or r.khoa_den is not null then update public.so_tay set sai = 0, khoa_den = null where ma = k; end if;
  return 'ok';
end $$;
revoke all on function public.so_tay_kt(text, text) from public, anon, authenticated;

-- Mở sổ (p_tao = true: chưa có thì tạo mới với PIN này).
-- p_luc = lần lưu máy đang có; nếu trên mạng không có gì mới thì không gửi lại dữ liệu (đỡ tốn băng thông).
drop function if exists public.so_tay_mo(text, text, boolean);
create or replace function public.so_tay_mo(p_ma text, p_pin text, p_tao boolean default false, p_luc timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k text := lower(trim(coalesce(p_ma, ''))); kq text; r public.so_tay;
begin
  kq := public.so_tay_kt(k, p_pin);
  if kq = 'chua_co' and p_tao then
    insert into public.so_tay (ma, pin_hash) values (k, crypt(p_pin, gen_salt('bf', 8)));
    return jsonb_build_object('ok', true, 'moi', true, 'du_lieu', '{}'::jsonb, 'sua_luc', now());
  end if;
  if kq <> 'ok' then return jsonb_build_object('loi', kq); end if;
  select * into r from public.so_tay where ma = k;
  if p_luc is not null and r.sua_luc = p_luc then return jsonb_build_object('ok', true, 'giong', true, 'sua_luc', r.sua_luc); end if;
  return jsonb_build_object('ok', true, 'du_lieu', r.du_lieu, 'sua_luc', r.sua_luc);
end $$;

-- Lưu cả sổ (ghi đè). Giới hạn ~1 MB mỗi sổ.
create or replace function public.so_tay_luu(p_ma text, p_pin text, p_du_lieu jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k text := lower(trim(coalesce(p_ma, ''))); kq text; luc timestamptz := now();
begin
  kq := public.so_tay_kt(k, p_pin);
  if kq <> 'ok' then return jsonb_build_object('loi', kq); end if;
  if jsonb_typeof(p_du_lieu) <> 'object' or pg_column_size(p_du_lieu) > 1000000 then return jsonb_build_object('loi', 'lon'); end if;
  update public.so_tay set du_lieu = p_du_lieu, sua_luc = luc where ma = k;
  return jsonb_build_object('ok', true, 'sua_luc', luc);
end $$;

revoke all on function public.so_tay_mo(text, text, boolean, timestamptz) from public;
revoke all on function public.so_tay_luu(text, text, jsonb) from public;
grant execute on function public.so_tay_mo(text, text, boolean, timestamptz) to anon, authenticated;
grant execute on function public.so_tay_luu(text, text, jsonb) to anon, authenticated;
