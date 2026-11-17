-- Thống kê chi tiết cho trang admin › Lượt truy cập.
-- Chạy 1 lần trong Supabase › SQL Editor (dán cả file rồi bấm Run). Chạy lại cũng không sao.
-- Đọc bảng page_views (đã có), so_tay, chat, chat_bao, feedback. Giờ tính theo giờ Việt Nam.
-- "Phiên" = một lần vào web: các lượt xem của cùng một máy cách nhau không quá 30 phút.

create index if not exists page_views_created_at on public.page_views (created_at);
create index if not exists page_views_visitor on public.page_views (visitor, created_at);

create or replace function public.thong_ke_chi_tiet(p_tu date, p_den date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  tz constant text := 'Asia/Ho_Chi_Minh';
  a timestamptz; b timestamptz; a0 timestamptz; kq jsonb;
begin
  if not coalesce(public.is_admin(), false) then raise exception 'chỉ admin'; end if;
  if p_tu is null or p_den is null or p_den < p_tu then raise exception 'khoảng ngày sai'; end if;
  if p_den - p_tu > 400 then raise exception 'tối đa 400 ngày'; end if;
  a := p_tu::timestamp at time zone tz;
  b := (p_den + 1)::timestamp at time zone tz;
  a0 := a - (b - a);  -- kỳ trước cùng độ dài

  with
  v as (select pv.visitor, pv.path, pv.loai, pv.chi_tiet, pv.thiet_bi, pv.nguon, pv.created_at, pv.created_at at time zone tz as l
        from public.page_views pv where pv.created_at >= a0 and pv.created_at < b),
  ht as (select * from v where created_at >= a),
  tr as (select * from v where created_at < a),
  dau as (select pv.visitor, min(pv.created_at) as f from public.page_views pv where pv.visitor in (select distinct visitor from ht) group by pv.visitor),
  -- phiên: tách khi cách lượt trước > 30 phút
  x1 as (select visitor, path, created_at,
           case when lag(created_at) over w is null or created_at - lag(created_at) over w > interval '30 minutes' then 1 else 0 end as moi
         from ht where loai = 'xem' window w as (partition by visitor order by created_at)),
  x2 as (select *, sum(moi) over (partition by visitor order by created_at) as so_phien from x1),
  ph as (select visitor, so_phien, count(*) as luot, max(created_at) - min(created_at) as dai from x2 group by visitor, so_phien),
  x1t as (select case when lag(created_at) over (partition by visitor order by created_at) is null
                  or created_at - lag(created_at) over (partition by visitor order by created_at) > interval '30 minutes' then 1 else 0 end as moi
          from tr where loai = 'xem'),
  ngay as (select gs::date as d from generate_series(p_tu::timestamp, p_den::timestamp, interval '1 day') gs)
  select jsonb_build_object(
    'tu', p_tu, 'den', p_den, 'so_ngay', p_den - p_tu + 1,
    'tong', jsonb_build_object(
      'u', (select count(distinct visitor) from ht),
      'v', (select count(*) from ht where loai = 'xem'),
      'phien', (select count(*) from ph),
      'phut_tb', (select round(coalesce(avg(extract(epoch from dai)) filter (where luot > 1), 0) / 60.0, 1) from ph),
      'mot_trang', (select count(*) from ph where luot = 1),
      'moi', (select count(*) from dau where f >= a),
      'nhieu_ngay', (select count(*) from (select visitor from ht group by visitor having count(distinct l::date) >= 2) q),
      'nhap', (select count(*) from ht where loai = 'bam' and path = 'nhap-tu'),
      'bam', (select count(*) from ht where loai = 'bam'),
      'tim', (select count(*) from ht where loai = 'tim'),
      'u_truoc', (select count(distinct visitor) from tr),
      'v_truoc', (select count(*) from tr where loai = 'xem'),
      'phien_truoc', (select coalesce(sum(moi), 0) from x1t),
      'nhap_truoc', (select count(*) from tr where loai = 'bam' and path = 'nhap-tu')
    ),
    'ngay', (select coalesce(jsonb_agg(jsonb_build_object('d', to_char(n.d, 'YYYY-MM-DD'),
                'u', coalesce(q.u, 0), 'v', coalesce(q.v, 0), 'moi', coalesce(m.moi, 0)) order by n.d), '[]'::jsonb)
             from ngay n
             left join (select l::date as d, count(distinct visitor) as u, count(*) filter (where loai = 'xem') as v from ht group by 1) q on q.d = n.d
             left join (select (f at time zone tz)::date as d, count(*) as moi from dau where f >= a group by 1) m on m.d = n.d),
    'gio_thu', (select coalesce(jsonb_agg(jsonb_build_object('t', t, 'h', h, 'v', c)), '[]'::jsonb)
                from (select (extract(isodow from l)::int - 1) as t, extract(hour from l)::int as h, count(*) as c from ht where loai = 'xem' group by 1, 2) q),
    'muc', (select coalesce(jsonb_agg(jsonb_build_object('k', path, 'v', c, 'u', u) order by c desc), '[]'::jsonb)
            from (select path, count(*) as c, count(distinct visitor) as u from ht where loai = 'xem' group by path order by 2 desc limit 30) q),
    'vao', (select coalesce(jsonb_agg(jsonb_build_object('k', path, 'v', c) order by c desc), '[]'::jsonb)
            from (select path, count(*) as c from x2 where moi = 1 group by path order by 2 desc limit 15) q),
    'bam', (select coalesce(jsonb_agg(jsonb_build_object('k', path, 'v', c, 'u', u) order by c desc), '[]'::jsonb)
            from (select path, count(*) as c, count(distinct visitor) as u from ht where loai = 'bam' group by path order by 2 desc limit 30) q),
    'chu_de', (select coalesce(jsonb_agg(jsonb_build_object('k', chi_tiet, 'v', c) order by c desc), '[]'::jsonb)
               from (select chi_tiet, count(*) as c from ht where loai = 'bam' and path = 'chu-de' and chi_tiet is not null group by 1 order by 2 desc limit 20) q),
    'sap', (select coalesce(jsonb_agg(jsonb_build_object('k', chi_tiet, 'v', c) order by c desc), '[]'::jsonb)
            from (select chi_tiet, count(*) as c from ht where loai = 'bam' and path = 'chi-tiet-sap' and chi_tiet is not null group by 1 order by 2 desc limit 20) q),
    'bo', (select coalesce(jsonb_agg(jsonb_build_object('k', chi_tiet, 'v', c) order by c desc), '[]'::jsonb)
           from (select chi_tiet, count(*) as c from ht where loai = 'bam' and path = 'them-ca-bo' and chi_tiet is not null group by 1 order by 2 desc limit 20) q),
    'tim', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'v', c) order by c desc), '[]'::jsonb)
            from (select lower(chi_tiet) as k, count(*) as c from ht where loai = 'tim' and chi_tiet is not null group by 1 order by 2 desc limit 20) q),
    'thiet_bi', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'v', c) order by c desc), '[]'::jsonb)
                 from (select coalesce(thiet_bi, '?') as k, count(distinct visitor) as c from ht group by 1) q),
    'nguon', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'v', c) order by c desc), '[]'::jsonb)
              from (select coalesce(nguon, '?') as k, count(distinct visitor) as c from ht group by 1) q),
    'cong_dong', jsonb_build_object(
      'so_tong', (select count(*) from public.so_tay),
      'so_moi', (select count(*) from public.so_tay where tao_luc >= a and tao_luc < b),
      'so_dung', (select count(*) from public.so_tay where sua_luc >= a and sua_luc < b),
      'chat_tin', (select count(*) from public.chat where tao_luc >= a and tao_luc < b),
      'chat_nguoi', (select count(distinct ma) from public.chat where tao_luc >= a and tao_luc < b),
      'chat_bao', (select count(*) from public.chat_bao where luc >= a and luc < b),
      'gop_y', (select count(*) from public.feedback where created_at >= a and created_at < b)
    )
  ) into kq;
  return kq;
end $$;

revoke all on function public.thong_ke_chi_tiet(date, date) from public, anon;
grant execute on function public.thong_ke_chi_tiet(date, date) to authenticated;
