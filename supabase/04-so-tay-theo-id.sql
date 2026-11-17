-- Lưu tủ đồ, bộ đã lưu và Tích KC theo ID + mã PIN (không cần email).
-- Chạy 1 lần trong Supabase › SQL Editor (dán cả file rồi bấm Run). Chạy lại cũng không sao.
-- Cần có sẵn hàm is_admin() (file 01-gop-y.sql) cho phần admin.
--
-- Bảng không mở cho ai đọc thẳng: web chỉ gọi các hàm bên dưới, hàm tự kiểm tra PIN.
-- PIN và mã khôi phục lưu dạng băm bcrypt (không ai xem được bản gốc, kể cả admin).
-- Sai PIN / mã khôi phục 10 lần liền thì ID đó bị khóa 15 phút.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.so_tay (
  ma text primary key check (ma ~ '^[a-z0-9_.-]{3,32}$'),
  pin_hash text not null,
  kp_hash text,                         -- mã khôi phục (người chơi giữ, dùng khi quên PIN)
  du_lieu jsonb not null default '{}'::jsonb,
  sai int not null default 0,
  khoa_den timestamptz,
  tao_luc timestamptz not null default now(),
  sua_luc timestamptz not null default now()
);
alter table public.so_tay add column if not exists kp_hash text;
alter table public.so_tay enable row level security;  -- không có policy: chỉ đi qua các hàm bên dưới
revoke all on public.so_tay from anon, authenticated;

-- Mã khôi phục 8 ký tự dễ đọc (bỏ 0 O 1 I L), dạng ABCD-EFGH
create or replace function public.so_tay_tao_kp() returns text
language plpgsql set search_path = public, extensions as $$
declare b bytea := gen_random_bytes(8); chu text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; s text := ''; i int;
begin
  for i in 0..7 loop s := s || substr(chu, (get_byte(b, i) % length(chu)) + 1, 1); end loop;
  return substr(s, 1, 4) || '-' || substr(s, 5, 4);
end $$;
create or replace function public.so_tay_kp_sach(t text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g')) $$;

-- Ghi 1 lần sai (sai đủ 10 lần thì khóa 15 phút)
create or replace function public.so_tay_ghi_sai(k text) returns void
language sql security definer set search_path = public as $$
  update public.so_tay set
    sai = case when sai + 1 >= 10 then 0 else sai + 1 end,
    khoa_den = case when sai + 1 >= 10 then now() + interval '15 minutes' else khoa_den end
  where ma = k;
$$;

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
  if r.pin_hash <> crypt(p_pin, r.pin_hash) then perform public.so_tay_ghi_sai(k); return 'sai_pin'; end if;
  if r.sai <> 0 or r.khoa_den is not null then update public.so_tay set sai = 0, khoa_den = null where ma = k; end if;
  return 'ok';
end $$;

-- Mở sổ (p_tao = true: chưa có thì tạo mới với PIN này, trả kèm mã khôi phục, chỉ 1 lần duy nhất).
-- p_luc = lần lưu máy đang có; nếu trên mạng không có gì mới thì không gửi lại dữ liệu (đỡ tốn băng thông).
drop function if exists public.so_tay_mo(text, text, boolean);
create or replace function public.so_tay_mo(p_ma text, p_pin text, p_tao boolean default false, p_luc timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k text := lower(trim(coalesce(p_ma, ''))); kq text; r public.so_tay; kp text;
begin
  kq := public.so_tay_kt(k, p_pin);
  if kq = 'chua_co' and p_tao then
    kp := public.so_tay_tao_kp();
    insert into public.so_tay (ma, pin_hash, kp_hash) values (k, crypt(p_pin, gen_salt('bf', 8)), crypt(public.so_tay_kp_sach(kp), gen_salt('bf', 8)));
    return jsonb_build_object('ok', true, 'moi', true, 'khoi_phuc', kp, 'du_lieu', '{}'::jsonb, 'sua_luc', now());
  end if;
  if kq <> 'ok' then return jsonb_build_object('loi', kq); end if;
  select * into r from public.so_tay where ma = k;
  if p_luc is not null and r.sua_luc = p_luc then return jsonb_build_object('ok', true, 'giong', true, 'sua_luc', r.sua_luc, 'co_kp', r.kp_hash is not null); end if;
  return jsonb_build_object('ok', true, 'du_lieu', r.du_lieu, 'sua_luc', r.sua_luc, 'co_kp', r.kp_hash is not null);
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

-- Đổi PIN khi còn nhớ PIN cũ
create or replace function public.so_tay_doi_pin(p_ma text, p_pin text, p_pin_moi text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k text := lower(trim(coalesce(p_ma, ''))); kq text;
begin
  if coalesce(p_pin_moi, '') !~ '^[0-9]{4,8}$' then return jsonb_build_object('loi', 'pin'); end if;
  kq := public.so_tay_kt(k, p_pin);
  if kq <> 'ok' then return jsonb_build_object('loi', kq); end if;
  update public.so_tay set pin_hash = crypt(p_pin_moi, gen_salt('bf', 8)) where ma = k;
  return jsonb_build_object('ok', true);
end $$;

-- Tạo mã khôi phục mới (cần PIN). Mã cũ hết dùng được.
create or replace function public.so_tay_kp_moi(p_ma text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k text := lower(trim(coalesce(p_ma, ''))); kq text; kp text;
begin
  kq := public.so_tay_kt(k, p_pin);
  if kq <> 'ok' then return jsonb_build_object('loi', kq); end if;
  kp := public.so_tay_tao_kp();
  update public.so_tay set kp_hash = crypt(public.so_tay_kp_sach(kp), gen_salt('bf', 8)) where ma = k;
  return jsonb_build_object('ok', true, 'khoi_phuc', kp);
end $$;

-- Quên PIN: dùng mã khôi phục để đặt PIN mới
create or replace function public.so_tay_khoi_phuc(p_ma text, p_kp text, p_pin_moi text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare k text := lower(trim(coalesce(p_ma, ''))); r public.so_tay; kp text := public.so_tay_kp_sach(p_kp);
begin
  if k !~ '^[a-z0-9_.-]{3,32}$' then return jsonb_build_object('loi', 'ma'); end if;
  if coalesce(p_pin_moi, '') !~ '^[0-9]{4,8}$' then return jsonb_build_object('loi', 'pin'); end if;
  select * into r from public.so_tay where ma = k for update;
  if not found then return jsonb_build_object('loi', 'chua_co'); end if;
  if r.khoa_den is not null and r.khoa_den > now() then return jsonb_build_object('loi', 'khoa'); end if;
  if r.kp_hash is null then return jsonb_build_object('loi', 'khong_kp'); end if;
  if length(kp) <> 8 or r.kp_hash <> crypt(kp, r.kp_hash) then perform public.so_tay_ghi_sai(k); return jsonb_build_object('loi', 'sai_kp'); end if;
  update public.so_tay set pin_hash = crypt(p_pin_moi, gen_salt('bf', 8)), sai = 0, khoa_den = null where ma = k;
  return jsonb_build_object('ok', true);
end $$;

-- ===== Admin (đã đăng nhập trang #admin) =====
drop function if exists public.so_tay_admin_ds(text);
create or replace function public.so_tay_admin_ds(p_tim text default '')
returns table (ma text, tao_luc timestamptz, sua_luc timestamptz, so_mon int, so_bo int, co_kp boolean, dang_khoa boolean)
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  return query select s.ma, s.tao_luc, s.sua_luc,
      coalesce((s.du_lieu -> 'ward' ->> 'count')::int, 0),
      case when jsonb_typeof(s.du_lieu -> 'bo2') = 'array' then jsonb_array_length(s.du_lieu -> 'bo2') else 0 end,
      s.kp_hash is not null, coalesce(s.khoa_den > now(), false)
    from public.so_tay s
    where coalesce(p_tim, '') = '' or s.ma like '%' || lower(trim(p_tim)) || '%'
    order by s.sua_luc desc limit 100;
end $$;

-- Admin đặt PIN mới (6 số ngẫu nhiên, chỉ hiện cho admin 1 lần) và mở khóa
create or replace function public.so_tay_admin_pin(p_ma text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare pin text := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint & 2147483647) % 1000000)::text, 6, '0');
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  update public.so_tay set pin_hash = crypt(pin, gen_salt('bf', 8)), sai = 0, khoa_den = null where ma = lower(trim(p_ma));
  if not found then return jsonb_build_object('loi', 'chua_co'); end if;
  return jsonb_build_object('ok', true, 'pin', pin);
end $$;

create or replace function public.so_tay_admin_xoa(p_ma text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  delete from public.so_tay where ma = lower(trim(p_ma));
  return jsonb_build_object('ok', found);
end $$;

-- ===== Quyền gọi hàm =====
revoke all on function public.so_tay_tao_kp() from public, anon, authenticated;
revoke all on function public.so_tay_ghi_sai(text) from public, anon, authenticated;
revoke all on function public.so_tay_kt(text, text) from public, anon, authenticated;
revoke all on function public.so_tay_mo(text, text, boolean, timestamptz) from public;
revoke all on function public.so_tay_luu(text, text, jsonb) from public;
revoke all on function public.so_tay_doi_pin(text, text, text) from public;
revoke all on function public.so_tay_kp_moi(text, text) from public;
revoke all on function public.so_tay_khoi_phuc(text, text, text) from public;
revoke all on function public.so_tay_admin_ds(text) from public, anon;
revoke all on function public.so_tay_admin_pin(text) from public, anon;
revoke all on function public.so_tay_admin_xoa(text) from public, anon;
grant execute on function public.so_tay_mo(text, text, boolean, timestamptz) to anon, authenticated;
grant execute on function public.so_tay_luu(text, text, jsonb) to anon, authenticated;
grant execute on function public.so_tay_doi_pin(text, text, text) to anon, authenticated;
grant execute on function public.so_tay_kp_moi(text, text) to anon, authenticated;
grant execute on function public.so_tay_khoi_phuc(text, text, text) to anon, authenticated;
grant execute on function public.so_tay_admin_ds(text) to authenticated;
grant execute on function public.so_tay_admin_pin(text) to authenticated;
grant execute on function public.so_tay_admin_xoa(text) to authenticated;
