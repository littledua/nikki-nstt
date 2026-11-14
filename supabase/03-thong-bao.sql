-- Thông báo về điện thoại khi có góp ý mới.
-- Chạy 1 lần trong Supabase › SQL Editor (dán cả file rồi bấm Run). Chạy lại cũng không sao.
-- Cần có sẵn: bảng feedback và hàm is_admin() (file 01-gop-y.sql).

create extension if not exists pg_net;

-- Cấu hình: mã bí mật để trigger gọi Edge Function, cặp khóa VAPID (Edge Function tự tạo lần đầu).
-- Không có policy nào nên chỉ máy chủ (service role) đọc được.
create table if not exists public.push_cfg (
  id int primary key default 1 check (id = 1),
  bi_mat text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  vapid_pub text,
  vapid_priv text
);
insert into public.push_cfg (id) values (1) on conflict (id) do nothing;
alter table public.push_cfg enable row level security;

-- Mỗi điện thoại / trình duyệt đã bật thông báo là một dòng
create table if not exists public.push_subs (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  thiet_bi text,
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;
drop policy if exists "admin xem may cua minh" on public.push_subs;
drop policy if exists "admin them may" on public.push_subs;
drop policy if exists "admin sua may" on public.push_subs;
drop policy if exists "admin xoa may" on public.push_subs;
create policy "admin xem may cua minh" on public.push_subs for select to authenticated using (user_id = auth.uid() and public.is_admin());
create policy "admin them may" on public.push_subs for insert to authenticated with check (user_id = auth.uid() and public.is_admin());
create policy "admin sua may" on public.push_subs for update to authenticated using (user_id = auth.uid() and public.is_admin()) with check (user_id = auth.uid());
create policy "admin xoa may" on public.push_subs for delete to authenticated using (user_id = auth.uid() and public.is_admin());

-- Có góp ý mới thì gọi Edge Function bao-gop-y để gửi thông báo
create or replace function public.bao_gop_y_moi() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform net.http_post(
    url := 'https://yxlrhuzkgdigoacowsee.supabase.co/functions/v1/bao-gop-y',
    body := jsonb_build_object('loai', 'gop-y', 'ten', new.name, 'noi_dung', new.message, 'trang', new.page),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-bao', (select bi_mat from public.push_cfg where id = 1))
  );
  return new;
exception when others then
  return new; -- lỗi gửi thông báo không được làm hỏng việc lưu góp ý
end $$;

drop trigger if exists bao_gop_y_moi on public.feedback;
create trigger bao_gop_y_moi after insert on public.feedback for each row execute function public.bao_gop_y_moi();
