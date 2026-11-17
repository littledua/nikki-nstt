-- Phòng chat chung. Ai cũng đọc được; muốn nhắn phải có Sổ của tôi (ID + PIN).
-- Chạy 1 lần trong Supabase › SQL Editor (dán cả file rồi bấm Run). Chạy lại cũng không sao.
-- Cần có sẵn: file 04-so-tay-theo-id.sql (bảng so_tay, hàm so_tay_kt) và hàm is_admin().
--
-- Chống spam: tối đa 500 ký tự/tin, cách nhau ít nhất 5 giây, tối đa 20 tin/10 phút mỗi ID.
-- Từ tục trong bảng chat_tu tự đổi thành ***. 3 người báo cáo thì tin tự ẩn chờ admin xem.
-- Tin cũ hơn 30 ngày tự xóa.

create table if not exists public.chat (
  id bigint generated always as identity primary key,
  ma text not null references public.so_tay (ma) on delete cascade,
  noi_dung text not null check (char_length(noi_dung) between 1 and 500),
  tao_luc timestamptz not null default now(),
  an boolean not null default false,
  bao_cao int not null default 0
);
create index if not exists chat_ma_luc on public.chat (ma, tao_luc desc);
create table if not exists public.chat_bao (chat_id bigint references public.chat (id) on delete cascade, nguoi text not null, luc timestamptz not null default now(), primary key (chat_id, nguoi));
create table if not exists public.chat_cam (ma text primary key, ly_do text, luc timestamptz not null default now());
create table if not exists public.chat_tu (tu text primary key);
alter table public.chat enable row level security;
alter table public.chat_bao enable row level security;
alter table public.chat_cam enable row level security;
alter table public.chat_tu enable row level security;
revoke all on public.chat, public.chat_bao, public.chat_cam, public.chat_tu from anon, authenticated;

-- Từ tục mặc định (admin sửa được). Chỉ khớp nguyên từ, nên "đeo", "đi" không bị che nhầm.
insert into public.chat_tu (tu) values
  ('đm'), ('dm'), ('đmm'), ('dmm'), ('đcm'), ('dcm'), ('đkm'), ('dkm'), ('cmm'), ('clm'), ('cl'), ('vcl'), ('vkl'), ('vl'), ('clgt'), ('đéo'), ('đếch'),
  ('địt'), ('đụ'), ('lồn'), ('cặc'), ('buồi'), ('đĩ'), ('chó đẻ'), ('óc chó'), ('mẹ mày'), ('con mẹ mày'), ('fuck'), ('shit'), ('bitch'), ('dmcs')
on conflict do nothing;

-- Che từ tục: ghép nguyên từ, ranh giới là khoảng trắng hoặc dấu câu
create or replace function public.chat_loc(t text) returns text
language plpgsql stable security definer set search_path = public as $$
declare w record; ra text := t; bien text := '(^|[[:space:].,!?;:"''()\[\]{}<>/\\~*_+=@#$%^&|-])';
begin
  for w in select tu from public.chat_tu order by char_length(tu) desc loop
    ra := regexp_replace(ra, bien || '(' || regexp_replace(w.tu, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || ')(?=$|[[:space:].,!?;:"''()\[\]{}<>/\\~*_+=@#$%^&|-])', '\1' || repeat('*', char_length(w.tu)), 'gi');
  end loop;
  return ra;
end $$;

-- Đọc tin (ai cũng gọi được). p_sau: chỉ lấy tin mới hơn id này; p_truoc: lấy tin cũ hơn id này.
drop function if exists public.chat_doc(bigint, bigint);
create or replace function public.chat_doc(p_sau bigint default 0, p_truoc bigint default null)
returns table (id bigint, ma text, noi_dung text, tao_luc timestamptz)
language sql stable security definer set search_path = public as $$
  select * from (
    select c.id, c.ma, c.noi_dung, c.tao_luc from public.chat c
    where not c.an and c.id > coalesce(p_sau, 0) and (p_truoc is null or c.id < p_truoc)
    order by c.id desc limit 60
  ) x order by x.id;
$$;

-- Gửi tin
create or replace function public.chat_gui(p_ma text, p_pin text, p_noi_dung text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text := lower(trim(coalesce(p_ma, ''))); kq text; t text := btrim(regexp_replace(coalesce(p_noi_dung, ''), '[\r\n]{3,}', E'\n\n', 'g')); r public.chat;
begin
  kq := public.so_tay_kt(k, p_pin);
  if kq <> 'ok' then return jsonb_build_object('loi', kq); end if;
  if exists (select 1 from public.chat_cam where ma = k) then return jsonb_build_object('loi', 'cam'); end if;
  if char_length(t) = 0 then return jsonb_build_object('loi', 'trong'); end if;
  if char_length(t) > 500 then return jsonb_build_object('loi', 'dai'); end if;
  if exists (select 1 from public.chat where ma = k and tao_luc > now() - interval '5 seconds') then return jsonb_build_object('loi', 'nhanh'); end if;
  if (select count(*) from public.chat where ma = k and tao_luc > now() - interval '10 minutes') >= 20 then return jsonb_build_object('loi', 'nhieu'); end if;
  insert into public.chat (ma, noi_dung) values (k, public.chat_loc(t)) returning * into r;
  delete from public.chat where tao_luc < now() - interval '30 days';
  return jsonb_build_object('ok', true, 'id', r.id, 'noi_dung', r.noi_dung, 'tao_luc', r.tao_luc);
end $$;

-- Xóa tin của chính mình
create or replace function public.chat_xoa(p_ma text, p_pin text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text := lower(trim(coalesce(p_ma, ''))); kq text;
begin
  kq := public.so_tay_kt(k, p_pin);
  if kq <> 'ok' then return jsonb_build_object('loi', kq); end if;
  delete from public.chat where id = p_id and ma = k;
  return jsonb_build_object('ok', found);
end $$;

-- Báo cáo tin (mỗi ID báo 1 lần/tin). 3 báo cáo thì tin tự ẩn.
create or replace function public.chat_bao_cao(p_ma text, p_pin text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text := lower(trim(coalesce(p_ma, ''))); kq text; n int;
begin
  kq := public.so_tay_kt(k, p_pin);
  if kq <> 'ok' then return jsonb_build_object('loi', kq); end if;
  if not exists (select 1 from public.chat where id = p_id) then return jsonb_build_object('loi', 'mat'); end if;
  insert into public.chat_bao (chat_id, nguoi) values (p_id, k) on conflict do nothing;
  select count(*) into n from public.chat_bao where chat_id = p_id;
  update public.chat set bao_cao = n, an = (an or n >= 3) where id = p_id;
  return jsonb_build_object('ok', true, 'an', n >= 3);
end $$;

-- ===== Admin =====
drop function if exists public.chat_admin_ds(boolean);
create or replace function public.chat_admin_ds(p_chi_bao boolean default false)
returns table (id bigint, ma text, noi_dung text, tao_luc timestamptz, an boolean, bao_cao int, bi_cam boolean)
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  return query select c.id, c.ma, c.noi_dung, c.tao_luc, c.an, c.bao_cao, exists (select 1 from public.chat_cam m where m.ma = c.ma)
    from public.chat c where not p_chi_bao or c.bao_cao > 0 or c.an order by c.id desc limit 200;
end $$;

create or replace function public.chat_admin_sua(p_id bigint, p_lam text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  if p_lam = 'xoa' then delete from public.chat where id = p_id;
  elsif p_lam = 'an' then update public.chat set an = true where id = p_id;
  elsif p_lam = 'hien' then update public.chat set an = false, bao_cao = 0 where id = p_id; delete from public.chat_bao where chat_id = p_id;
  else return jsonb_build_object('loi', 'lam'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.chat_admin_cam(p_ma text, p_cam boolean, p_ly_do text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  if p_cam then insert into public.chat_cam (ma, ly_do) values (lower(trim(p_ma)), p_ly_do) on conflict (ma) do update set ly_do = excluded.ly_do, luc = now();
  else delete from public.chat_cam where ma = lower(trim(p_ma)); end if;
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.chat_admin_cam_ds();
create or replace function public.chat_admin_cam_ds() returns table (ma text, ly_do text, luc timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  return query select m.ma, m.ly_do, m.luc from public.chat_cam m order by m.luc desc;
end $$;

create or replace function public.chat_admin_tu(p_tu text[] default null) returns text[]
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  if p_tu is not null then
    delete from public.chat_tu;
    insert into public.chat_tu (tu) select distinct lower(btrim(x)) from unnest(p_tu) x where btrim(x) <> '' on conflict do nothing;
  end if;
  return array(select tu from public.chat_tu order by tu);
end $$;

-- ===== Quyền gọi hàm =====
revoke all on function public.chat_loc(text) from public, anon, authenticated;
revoke all on function public.chat_doc(bigint, bigint) from public;
revoke all on function public.chat_gui(text, text, text) from public;
revoke all on function public.chat_xoa(text, text, bigint) from public;
revoke all on function public.chat_bao_cao(text, text, bigint) from public;
revoke all on function public.chat_admin_ds(boolean) from public, anon;
revoke all on function public.chat_admin_sua(bigint, text) from public, anon;
revoke all on function public.chat_admin_cam(text, boolean, text) from public, anon;
revoke all on function public.chat_admin_cam_ds() from public, anon;
revoke all on function public.chat_admin_tu(text[]) from public, anon;
grant execute on function public.chat_doc(bigint, bigint) to anon, authenticated;
grant execute on function public.chat_gui(text, text, text) to anon, authenticated;
grant execute on function public.chat_xoa(text, text, bigint) to anon, authenticated;
grant execute on function public.chat_bao_cao(text, text, bigint) to anon, authenticated;
grant execute on function public.chat_admin_ds(boolean) to authenticated;
grant execute on function public.chat_admin_sua(bigint, text) to authenticated;
grant execute on function public.chat_admin_cam(text, boolean, text) to authenticated;
grant execute on function public.chat_admin_cam_ds() to authenticated;
grant execute on function public.chat_admin_tu(text[]) to authenticated;
