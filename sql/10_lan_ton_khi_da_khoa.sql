-- ═══════════════════════════════════════════════════════════════════════
-- 10_lan_ton_khi_da_khoa.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
-- Yêu cầu: đã chạy 02 và 05.
--
-- Bản in phải luôn khớp phần mềm → chốt theo thứ tự kỳ:
--   Tồn cuối kỳ N chỉ được đổ sang tồn đầu kỳ N+1 khi kỳ N của đơn vị ĐÃ KHOÁ (đã chốt/in).
--   Khoá đọc từ settings.lockedPeriods: "YYYY-MM" (toàn cục), "YYYY-MM_<tên đơn vị>" hoặc
--   "YYYY-MM_<unit_id>". Kỳ còn mở thì tồn đầu kỳ sau giữ nguyên cho tới khi kỳ đó được khoá
--   (app tự gọi lan tồn ngay khi khoá — qua In báo cáo hoặc Khoá/Mở).
-- File này dựng lại hàm cascade_opening_stock (bản 05) và chỉ THÊM điều kiện "đã khoá".
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.cascade_opening_stock(
  p_start text, p_unit_ids text[] default null, p_view_period text default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  s public.app_sessions;
  ids text[] := p_unit_ids;
  cur text := p_start; nxt text;
  step int; n int; total int := 0;
  v_rows json; v_view json := '[]'::json;
  lp jsonb;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;
  if p_start !~ '^\d{4}-\d{2}$' then raise exception 'ERR_BAD_PERIOD'; end if;

  -- Không phải admin: chỉ đơn vị của chính mình (đúng như app cũ)
  if coalesce(s.role, '') <> 'admin' then
    if p_unit_ids is null then ids := array[s.unit_id];
    else ids := array(select x from unnest(p_unit_ids) x where x = s.unit_id);
    end if;
    if coalesce(array_length(ids, 1), 0) = 0 then
      return json_build_object('updated', 0, 'view_rows', '[]'::json);
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('cascade_opening_stock'));

  select coalesce((select st.value::jsonb from public.settings st where st.key = 'lockedPeriods'), '{}'::jsonb)
    into lp;

  for step in 1..24 loop
    nxt := to_char(to_date(cur || '-01', 'YYYY-MM-DD') + interval '1 month', 'YYYY-MM');
    exit when not exists (select 1 from public.reports r
                          where r.period = nxt and (ids is null or r.unit_id::text = any(ids)));

    drop table if exists _cas;
    create temp table _cas on commit drop as
      select r.unit_id, coalesce(r.phan_loai, 'h2') as pl, coalesce(r.period_type, 'month') as pt,
             r.drug, r.lot, coalesce(r.exp, '') as ex,
             greatest(0, coalesce(r.open,0) + coalesce(r.tinh,0) + coalesce(r.ntk,0) + coalesce(r.dc,0) + coalesce(r.n4,0)
                         - coalesce(r.sd,0) - coalesce(r.dc2,0) - coalesce(r.dc3,0) - coalesce(r.hh,0)) as fin
      from public.reports r
      left join public.units u on u.id = r.unit_id
      where r.period = cur and r.unit_id is not null
        and (ids is null or r.unit_id::text = any(ids))
        -- CHỈ lan từ kỳ ĐÃ KHOÁ của đơn vị
        and (lp ? cur
             or lp ? (cur || '_' || r.unit_id::text)
             or (u.name is not null and lp ? (cur || '_' || u.name)));

    with u as (
      update public.reports n set open = c.fin
      from _cas c
      where n.period = nxt and n.unit_id = c.unit_id and coalesce(n.phan_loai, 'h2') = c.pl
        and n.drug = c.drug and n.lot = c.lot and coalesce(n.exp, '') = c.ex
        and coalesce(n.open, 0) <> c.fin
      returning n.unit_id, n.phan_loai, n.period_type, n.drug, n.lot, n.exp, n.open
    ), i as (
      insert into public.reports(unit_id, period, phan_loai, period_type, drug, lot, exp,
                                 open, tinh, ntk, dc, n4, sd, dc2, dc3, hh, locked)
      select c.unit_id, nxt, c.pl, c.pt, c.drug, c.lot, c.ex, c.fin, 0, 0, 0, 0, 0, 0, 0, 0, false
      from _cas c
      where c.fin > 0 and not exists (
        select 1 from public.reports n
        where n.period = nxt and n.unit_id = c.unit_id and coalesce(n.phan_loai, 'h2') = c.pl
          and n.drug = c.drug and n.lot = c.lot and coalesce(n.exp, '') = c.ex)
      on conflict do nothing
      returning unit_id, phan_loai, period_type, drug, lot, exp, open
    )
    select count(*), coalesce(json_agg(z), '[]'::json) into n, v_rows
    from (select * from u union all select * from i) z;

    exit when n = 0;            -- tồn đầu kỳ sau đã khớp (hoặc kỳ chưa khoá) → dừng lan
    total := total + n;
    if nxt = p_view_period then v_view := v_rows; end if;
    cur := nxt;
  end loop;

  return json_build_object('updated', total, 'view_rows', v_view);
end $$;
grant execute on function public.cascade_opening_stock(text, text[], text) to anon, authenticated;

notify pgrst, 'reload schema';

-- KIỂM TRA (chỉ đọc):
--   select prosrc like '%lockedPeriods%' from pg_proc where proname = 'cascade_opening_stock';  -- true
