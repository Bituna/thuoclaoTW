-- ═══════════════════════════════════════════════════════════════════════
-- 05_cot_thua_n4.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor TRƯỚC khi dùng bản app có cột "Thừa"
-- (chạy lại nhiều lần vẫn an toàn). Yêu cầu: đã chạy 01 và 02.
--
-- Thêm khoản nhập "Thừa" (thuốc thừa phát hiện khi kiểm kê) vào bảng reports:
--  1) Cột n4 (cùng kiểu số với cột sd hiện có), mặc định 0 → dữ liệu cũ = 0.
--  2) Lan tồn đầu kỳ: tồn cuối = open + tinh + ntk + dc + n4 − sd − dc2 − dc3 − hh.
--  3) Chống ghi đè: sửa ô Thừa cũng tính là "người dùng nhập số liệu".
-- Chỉ THÊM — không đổi/xoá cột cũ → bản app cũ vẫn chạy bình thường sau khi chạy file này.
--
-- Quy ước tên: trong code app dùng t0/n1/n2/n3/n4/x1/x2/x3/x4; database giữ tên cột cũ
-- (open/tinh/ntk/dc/sd/dc2/dc3/hh) + cột mới n4. App tự dịch tên ở lớp kết nối.
-- ═══════════════════════════════════════════════════════════════════════

-- 1) Cột n4 cùng kiểu với cột sd
do $$
declare v_type text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'reports' and column_name = 'n4') then
    select format_type(a.atttypid, a.atttypmod) into v_type
      from pg_attribute a
     where a.attrelid = 'public.reports'::regclass and a.attname = 'sd' and not a.attisdropped;
    execute format('alter table public.reports add column n4 %s not null default 0', coalesce(v_type, 'numeric'));
  end if;
end $$;

-- 2) Chống ghi đè (bản 02 + n4)
drop trigger if exists trg_b_edit_lock on public.reports;
create or replace function public.trg_reports_edit_lock()
returns trigger language plpgsql
as $$
begin
  if TG_OP = 'INSERT' then
    if NEW.edited_at is null then NEW.edited_at := clock_timestamp(); end if;
    -- giữ base_edited_at: với upsert (on conflict) giá trị này đi tiếp sang nhánh UPDATE
    return NEW;
  end if;

  -- UPDATE: chỉ coi là "app có gửi base" khi giá trị mới khác giá trị đang lưu
  if NEW.base_edited_at is not null
     and NEW.base_edited_at is distinct from OLD.base_edited_at
     and OLD.edited_at is not null
     and NEW.base_edited_at <> OLD.edited_at then
    raise exception 'ERR_CONFLICT: % | % | % | %', OLD.unit_id, OLD.drug, OLD.lot, OLD.period;
  end if;

  if (NEW.tinh, NEW.ntk, NEW.dc, NEW.n4, NEW.sd, NEW.dc2, NEW.dc3, NEW.hh, NEW.locked)
     is distinct from (OLD.tinh, OLD.ntk, OLD.dc, OLD.n4, OLD.sd, OLD.dc2, OLD.dc3, OLD.hh, OLD.locked) then
    NEW.edited_at := clock_timestamp();
  else
    NEW.edited_at := OLD.edited_at;
  end if;
  NEW.base_edited_at := null;
  return NEW;
end $$;

create trigger trg_b_edit_lock before insert or update on public.reports
  for each row execute function public.trg_reports_edit_lock();

-- 3) Lan tồn đầu kỳ trên máy chủ (bản 02 + n4)
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
      where r.period = cur and r.unit_id is not null
        and (ids is null or r.unit_id::text = any(ids));

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

    exit when n = 0;            -- tồn đầu kỳ sau đã khớp → dừng lan
    total := total + n;
    if nxt = p_view_period then v_view := v_rows; end if;
    cur := nxt;
  end loop;

  return json_build_object('updated', total, 'view_rows', v_view);
end $$;
grant execute on function public.cascade_opening_stock(text, text[], text) to anon, authenticated;

notify pgrst, 'reload schema';

-- Kiểm tra
select column_name, data_type, column_default from information_schema.columns
 where table_schema = 'public' and table_name = 'reports' and column_name = 'n4';
