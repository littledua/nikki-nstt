-- Tag "Admin" cho sổ của ban quản trị (hiện cạnh tên trong phòng chat) + chặn ID dễ gây nhầm.
-- Chạy 1 lần trong Supabase › SQL Editor (dán cả file rồi bấm Run). Chạy lại cũng không sao.
-- Cần có sẵn: 04-so-tay-theo-id.sql, 05-chat-chung.sql và hàm is_admin().
--
-- Gắn tag: đăng nhập trang #admin › Cài đặt › Sổ người chơi › Gắn tag Admin.

alter table public.so_tay add column if not exists quan_tri boolean not null default false;

-- Không cho người chơi tự tạo ID trông như ban quản trị
create or replace function public.so_tay_chan_ten() returns trigger
language plpgsql as $$
begin
  if new.ma in ('admin', 'admins', 'administrator', 'quantri', 'quan.tri', 'quan_tri', 'nikkidiary', 'nikki.diary', 'nikki_diary', 'mod', 'mods', 'moderator', 'support', 'hotro', 'ho.tro', 'system', 'he.thong')
     and not coalesce(public.is_admin(), false) then
    raise exception 'ten_danh_rieng' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists so_tay_chan_ten on public.so_tay;
create trigger so_tay_chan_ten before insert on public.so_tay for each row execute function public.so_tay_chan_ten();

-- Đọc tin kèm cờ Admin của người gửi
drop function if exists public.chat_doc(bigint, bigint);
create or replace function public.chat_doc(p_sau bigint default 0, p_truoc bigint default null)
returns table (id bigint, ma text, noi_dung text, tao_luc timestamptz, quan_tri boolean)
language sql stable security definer set search_path = public as $$
  select * from (
    select c.id, c.ma, c.noi_dung, c.tao_luc, coalesce(s.quan_tri, false) from public.chat c left join public.so_tay s on s.ma = c.ma
    where not c.an and c.id > coalesce(p_sau, 0) and (p_truoc is null or c.id < p_truoc)
    order by c.id desc limit 60
  ) x order by x.id;
$$;

-- Danh sách sổ cho admin (thêm cột quan_tri)
drop function if exists public.so_tay_admin_ds(text);
create or replace function public.so_tay_admin_ds(p_tim text default '')
returns table (ma text, tao_luc timestamptz, sua_luc timestamptz, so_mon int, so_bo int, co_kp boolean, dang_khoa boolean, quan_tri boolean)
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  return query select s.ma, s.tao_luc, s.sua_luc,
      coalesce((s.du_lieu -> 'ward' ->> 'count')::int, 0),
      case when jsonb_typeof(s.du_lieu -> 'bo2') = 'array' then jsonb_array_length(s.du_lieu -> 'bo2') else 0 end,
      s.kp_hash is not null, coalesce(s.khoa_den > now(), false), s.quan_tri
    from public.so_tay s
    where coalesce(p_tim, '') = '' or s.ma like '%' || lower(trim(p_tim)) || '%'
    order by s.quan_tri desc, s.sua_luc desc limit 100;
end $$;

-- Gắn / bỏ tag Admin
create or replace function public.so_tay_admin_tag(p_ma text, p_bat boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  update public.so_tay set quan_tri = coalesce(p_bat, false) where ma = lower(trim(p_ma));
  return jsonb_build_object('ok', found);
end $$;

revoke all on function public.so_tay_chan_ten() from public, anon, authenticated;
revoke all on function public.chat_doc(bigint, bigint) from public;
revoke all on function public.so_tay_admin_ds(text) from public, anon;
revoke all on function public.so_tay_admin_tag(text, boolean) from public, anon;
grant execute on function public.chat_doc(bigint, bigint) to anon, authenticated;
grant execute on function public.so_tay_admin_ds(text) to authenticated;
grant execute on function public.so_tay_admin_tag(text, boolean) to authenticated;
