-- ═══════════════════════════════════════════════════════════════════════
-- 11_sua_theo_kiem_toan.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
-- Yêu cầu: đã chạy 02, 05, 06, 07, 09, 10.
--
-- Sửa các điểm tìm thấy khi kiểm toán luồng tồn kho / điều chuyển:
--   1) Tồn cuối ÂM không còn bị "kẹp về 0" khi lan sang tồn đầu kỳ sau (số âm phải hiện ra để sửa).
--   2) Lan tồn đầu chạy được cả kỳ QUÝ (Hàng 1) ở máy chủ; khoá theo từng đơn vị (không còn 1 khoá
--      toàn cục làm mọi tỉnh phải xếp hàng); khoá kỳ theo TÊN đơn vị chỉ được tin khi tên là duy nhất.
--   3) Tồn đầu vừa được lan cũng làm đổi "mốc sửa" → máy đang giữ số cũ lưu đè sẽ bị báo xung đột.
--   4) Huỷ / từ chối phiếu: không cho đơn vị (không phải admin) làm đổi số của kỳ ĐÃ CHỐT; không để
--      tồn cuối bên nhận âm sau khi rút số.
--   5) Hàm mới transfer_move_date: admin đổi ngày phiếu, chuyển số giữa 2 kỳ TRỌN 1 GIAO DỊCH.
--   6) Hàm mới report_add_tinh: cộng/trừ cột Tỉnh cấp trong 1 câu lệnh (không mất số khi 2 máy cùng ghi).
--   7) Nhật ký ghi vào kỳ đã chốt (chỉ GHI NHẬT KÝ; bật chặn hẳn bằng app_config khi đã sẵn sàng).
--   8) Bổ sung khoá kỳ theo mã đơn vị (unit_id) cho các khoá cũ đang ghi theo tên.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 0) Công tắc (mặc định TẮT — bật khi đã rà dữ liệu, xem cuối file) ────
insert into public.app_config(key, value) values ('strict_period_lock', 'off') on conflict (key) do nothing;
insert into public.app_config(key, value) values ('cascade_zero_orphan', 'off') on conflict (key) do nothing;

create or replace function app_private._cfg_on(p_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.app_config where key = p_key), 'off') = 'on';
$$;
grant execute on function app_private._cfg_on(text) to anon, authenticated;

-- ── 1) Bỏ ràng buộc "tồn đầu >= 0" nếu có (tồn âm phải lan đúng để lộ ra, không bị chặn/kẹp) ──
do $$
declare c record;
begin
  for c in
    select con.conname
      from pg_constraint con
     where con.conrelid = 'public.reports'::regclass and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ~* '\mopen\M[^,]*>=\s*\(?0'
  loop
    execute format('alter table public.reports drop constraint %I', c.conname);
    raise notice 'Đã bỏ ràng buộc %', c.conname;
  end loop;
end $$;

-- ── 2) Kỳ của đơn vị đã khoá chưa? (1 quy tắc dùng chung cho mọi hàm) ─────
--   Khoá: "KỲ" (toàn cục) · "KỲ_<unit_id>" · "KỲ_<tên>" khi tên đó là DUY NHẤT trong cây đơn vị.
create or replace function app_private._period_locked_lp(lp jsonb, p_period text, p_unit text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_period is not null and (
           coalesce(lp, '{}'::jsonb) ? p_period
        or (p_unit is not null and coalesce(lp, '{}'::jsonb) ? (p_period || '_' || p_unit))
        or exists (select 1 from public.units u
                    where u.id::text = p_unit and u.name is not null
                      and coalesce(lp, '{}'::jsonb) ? (p_period || '_' || u.name)
                      and (select count(*) from public.units u2 where u2.name = u.name) = 1));
$$;
create or replace function app_private._period_locked(p_period text, p_unit text)
returns boolean language sql stable security definer set search_path = public as $$
  select app_private._period_locked_lp(
           coalesce((select st.value::jsonb from public.settings st where st.key = 'lockedPeriods'), '{}'::jsonb),
           p_period, p_unit);
$$;
grant execute on function app_private._period_locked_lp(jsonb, text, text) to anon, authenticated;
grant execute on function app_private._period_locked(text, text) to anon, authenticated;

create or replace function app_private._next_period(p text)
returns text language sql immutable as $$
  select case
    when p ~ '^\d{4}-\d{2}$' then to_char(to_date(p || '-01', 'YYYY-MM-DD') + interval '1 month', 'YYYY-MM')
    when p ~ '^\d{4}-Q[1-3]$' then left(p, 6) || (right(p, 1)::int + 1)::text
    when p ~ '^\d{4}-Q4$'     then (left(p, 4)::int + 1)::text || '-Q1'
    else null end;
$$;

-- ── 3) LAN TỒN ĐẦU (thay bản 10) ─────────────────────────────────────────
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
  lp jsonb; v_id text; v_zero boolean;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;
  if app_private._next_period(p_start) is null then raise exception 'ERR_BAD_PERIOD'; end if;

  -- Không phải admin: chỉ đơn vị của chính mình (đúng như app cũ)
  if coalesce(s.role, '') <> 'admin' then
    if p_unit_ids is null then ids := array[s.unit_id];
    else ids := array(select x from unnest(p_unit_ids) x where x = s.unit_id);
    end if;
    if coalesce(array_length(ids, 1), 0) = 0 then
      return json_build_object('updated', 0, 'view_rows', '[]'::json);
    end if;
  end if;

  -- Khoá tuần tự THEO ĐƠN VỊ: 2 tỉnh lan tồn cùng lúc không phải chờ nhau;
  -- lan "toàn bộ" (ids rỗng — admin) thì giữ khoá riêng toàn cục.
  if ids is null then
    perform pg_advisory_xact_lock(hashtext('cascade_opening_stock'), 0);
  else
    perform pg_advisory_xact_lock_shared(hashtext('cascade_opening_stock'), 0);
    for v_id in select distinct x from unnest(ids) x where x is not null order by 1 loop
      perform pg_advisory_xact_lock(hashtext('cascade_unit'), hashtext(v_id));
    end loop;
  end if;

  select coalesce((select st.value::jsonb from public.settings st where st.key = 'lockedPeriods'), '{}'::jsonb)
    into lp;
  v_zero := app_private._cfg_on('cascade_zero_orphan');

  for step in 1..24 loop
    nxt := app_private._next_period(cur);
    exit when nxt is null;
    exit when not exists (select 1 from public.reports r
                          where r.period = nxt and (ids is null or r.unit_id::text = any(ids)));

    drop table if exists _cas;
    create temp table _cas on commit drop as
      select r.unit_id, coalesce(r.phan_loai, 'h2') as pl, coalesce(r.period_type, 'month') as pt,
             r.drug, r.lot, coalesce(r.exp, '') as ex,
             -- KHÔNG kẹp về 0: tồn cuối âm lan đúng sang kỳ sau để lộ ra và được sửa tại nguồn
             (coalesce(r.open,0) + coalesce(r.tinh,0) + coalesce(r.ntk,0) + coalesce(r.dc,0) + coalesce(r.n4,0)
              - coalesce(r.sd,0) - coalesce(r.dc2,0) - coalesce(r.dc3,0) - coalesce(r.hh,0)) as fin
      from public.reports r
      where r.period = cur and r.unit_id is not null
        and (ids is null or r.unit_id::text = any(ids))
        -- CHỈ lan từ kỳ ĐÃ KHOÁ của đơn vị
        and app_private._period_locked_lp(lp, cur, r.unit_id::text);

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
      where c.fin <> 0 and not exists (
        select 1 from public.reports n
        where n.period = nxt and n.unit_id = c.unit_id and coalesce(n.phan_loai, 'h2') = c.pl
          and n.drug = c.drug and n.lot = c.lot and coalesce(n.exp, '') = c.ex)
      on conflict do nothing
      returning unit_id, phan_loai, period_type, drug, lot, exp, open
    ), o as (
      -- Lô "mồ côi": kỳ sau có tồn đầu nhưng kỳ trước (đã khoá) KHÔNG có lô đó → tồn đầu phải = 0.
      -- Chỉ chạy khi bật công tắc cascade_zero_orphan (xem cuối file) vì nó sửa số đang có.
      update public.reports n set open = 0
      where v_zero and n.period = nxt and coalesce(n.open, 0) <> 0
        and n.unit_id in (select distinct c.unit_id from _cas c)
        and not exists (select 1 from _cas c
                        where c.unit_id = n.unit_id and c.pl = coalesce(n.phan_loai, 'h2')
                          and c.drug = n.drug and c.lot = n.lot and c.ex = coalesce(n.exp, ''))
      returning n.unit_id, n.phan_loai, n.period_type, n.drug, n.lot, n.exp, n.open
    )
    select count(*), coalesce(json_agg(z), '[]'::json) into n, v_rows
    from (select * from u union all select * from i union all select * from o) z;

    exit when n = 0;            -- tồn đầu kỳ sau đã khớp (hoặc kỳ chưa khoá) → dừng lan
    total := total + n;
    if nxt = p_view_period then v_view := v_rows; end if;
    cur := nxt;
  end loop;

  return json_build_object('updated', total, 'view_rows', v_view);
end $$;
grant execute on function public.cascade_opening_stock(text, text[], text) to anon, authenticated;

-- ── 4) Khoá lạc quan: thêm cột open vào bộ so sánh ───────────────────────
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

  -- Có cột open: tồn đầu vừa được lan cũng làm đổi mốc → máy đang giữ số cũ lưu lại sẽ nhận ERR_CONFLICT
  if (NEW.open, NEW.tinh, NEW.ntk, NEW.dc, NEW.n4, NEW.sd, NEW.dc2, NEW.dc3, NEW.hh, NEW.locked)
     is distinct from (OLD.open, OLD.tinh, OLD.ntk, OLD.dc, OLD.n4, OLD.sd, OLD.dc2, OLD.dc3, OLD.hh, OLD.locked) then
    NEW.edited_at := clock_timestamp();
  else
    NEW.edited_at := OLD.edited_at;
  end if;
  NEW.base_edited_at := null;
  return NEW;
end $$;

-- ── 5) Tồn cuối của 1 lô (dùng để chặn rút số làm âm) ────────────────────
create or replace function app_private._lot_final(p_unit text, p_period text, p_drug text, p_lot text, p_exp text)
returns numeric language sql stable security definer set search_path = public as $$
  select sum(coalesce(r.open,0)+coalesce(r.tinh,0)+coalesce(r.ntk,0)+coalesce(r.dc,0)+coalesce(r.n4,0)
            -coalesce(r.sd,0)-coalesce(r.dc2,0)-coalesce(r.dc3,0)-coalesce(r.hh,0))
    from public.reports r
   where r.unit_id::text = p_unit and r.period = p_period and r.drug = p_drug and r.lot = p_lot
     and coalesce(r.exp, '') = coalesce(p_exp, '');
$$;
revoke all on function app_private._lot_final(text, text, text, text, text) from public, anon, authenticated;

-- ── 6) TỪ CHỐI phiếu (bản 06 + không đổi số kỳ đã chốt) ──────────────────
create or replace function public.transfer_reject(p_id uuid)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  s public.app_sessions;
  t public.transfers%rowtype;
  v_per text; v_unit text;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;

  select * into t from public.transfers where id = p_id for update;
  if not found then raise exception 'ERR_NOT_FOUND'; end if;
  if not app_private._tx_can(s, t.to_unit_id::text) then raise exception 'ERR_FORBIDDEN_UNIT'; end if;
  if t.status is distinct from 'pending' then
    return json_build_object('result', 'not_pending', 'status', t.status);
  end if;

  v_per := t.period;
  -- Từ chối làm đổi số của bên gửi (hoặc Tỉnh cấp của bên nhận với phiếu Tổ CL) ở kỳ của phiếu.
  v_unit := case when t.type = 'dc3_to_tinh' then t.to_unit_id::text else t.from_unit_id::text end;
  if coalesce(s.role, '') <> 'admin' and app_private._period_locked(v_per, v_unit) then
    raise exception 'ERR_LOCKED: kỳ % của đơn vị liên quan đã chốt — nhờ quản trị viên mở kỳ hoặc xử lý phiếu', v_per;
  end if;

  update public.transfers
     set status = 'rejected', notif_for = t.from_unit, notif_read = false
   where id = p_id;

  if t.type = 'dc2_to_dc' then
    perform app_private._rep_add(t.from_unit_id::text, v_per, t.drug, t.lot, t.exp, 'dc2', -coalesce(t.qty, 0), false);
  elsif t.type = 'dc3_province' then
    perform app_private._rep_add(t.from_unit_id::text, v_per, t.drug, t.lot, t.exp, 'dc3', -coalesce(t.qty, 0), false);
  elsif t.type = 'dc3_to_tinh' then
    perform app_private._rep_add(t.to_unit_id::text, v_per, t.drug, t.lot, t.exp, 'tinh', -coalesce(t.qty, 0), false);
    if coalesce(app_private._lot_final(t.to_unit_id::text, v_per, t.drug, t.lot, t.exp), 0) < 0 then
      raise exception 'ERR_NEGATIVE: đơn vị nhận đã dùng số thuốc này trong kỳ % — rút ra sẽ làm tồn cuối âm', v_per;
    end if;
  end if;

  return json_build_object('result', 'ok', 'type', t.type, 'period', v_per);
end $$;

-- ── 7) HUỶ phiếu (bản 06 + không đổi số kỳ đã chốt + không để bên nhận âm) ─
create or replace function public.transfer_cancel(p_id uuid)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  s public.app_sessions;
  t public.transfers%rowtype;
  v_was_conf boolean; v_rx text; v_dst_col text; v_dst_per text; v_admin boolean;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;
  v_admin := coalesce(s.role, '') = 'admin';

  select * into t from public.transfers where id = p_id for update;
  if not found then raise exception 'ERR_NOT_FOUND'; end if;
  if not (app_private._tx_can(s, t.from_unit_id::text) or app_private._tx_can(s, t.to_unit_id::text)) then
    raise exception 'ERR_FORBIDDEN_UNIT';
  end if;
  if t.status not in ('pending', 'confirmed') then
    return json_build_object('result', 'not_active', 'status', t.status);
  end if;
  v_was_conf := (t.status = 'confirmed');

  -- kỳ + cột bị rút ở bên nhận
  v_rx := case when t.receive_date is not null then app_private._period_of(t.receive_date::date, t.period) else t.period end;
  if t.type = 'dc3_to_tinh' then
    v_dst_col := 'tinh'; v_dst_per := t.period;
  elsif v_was_conf and t.type = 'dc2_to_dc' then
    v_dst_col := 'dc'; v_dst_per := v_rx;
  elsif v_was_conf and t.type = 'dc3_province' then
    v_dst_col := 'ntk'; v_dst_per := v_rx;
  end if;

  -- Đơn vị (không phải admin) không được làm đổi số của kỳ ĐÃ CHỐT ở bất kỳ bên nào
  if not v_admin then
    if t.type in ('dc2_to_dc', 'dc3_province') and app_private._period_locked(t.period, t.from_unit_id::text) then
      raise exception 'ERR_LOCKED: kỳ % của đơn vị gửi đã chốt — nhờ quản trị viên mở kỳ hoặc huỷ phiếu', t.period;
    end if;
    if v_dst_col is not null and t.to_unit_id is not null
       and app_private._period_locked(v_dst_per, t.to_unit_id::text) then
      raise exception 'ERR_LOCKED: kỳ % của đơn vị nhận đã chốt — nhờ quản trị viên mở kỳ hoặc huỷ phiếu', v_dst_per;
    end if;
  end if;

  update public.transfers
     set status = 'cancelled', notif_for = t.to_unit, notif_read = false
   where id = p_id;

  -- thông báo cho bên gửi (giống app)
  insert into public.transfers(period, period_type, from_unit, to_unit, from_unit_id, to_unit_id,
                               drug, lot, exp, qty, phan_loai, type, status, notif_for, notif_read)
  values (t.period, t.period_type, t.from_unit, t.to_unit, t.from_unit_id, t.to_unit_id,
          t.drug, t.lot, coalesce(t.exp, ''), t.qty, t.phan_loai, 'cancel_notif', 'cancelled', t.from_unit, false);

  -- bên gửi
  if t.type = 'dc2_to_dc' then
    perform app_private._rep_add(t.from_unit_id::text, t.period, t.drug, t.lot, t.exp, 'dc2', -coalesce(t.qty, 0), false);
  elsif t.type = 'dc3_province' then
    perform app_private._rep_add(t.from_unit_id::text, t.period, t.drug, t.lot, t.exp, 'dc3', -coalesce(t.qty, 0), false);
  end if;

  -- bên nhận
  if v_dst_col is not null and t.to_unit_id is not null then
    perform app_private._rep_add(t.to_unit_id::text, v_dst_per, t.drug, t.lot, t.exp, v_dst_col, -coalesce(t.qty, 0), false);
    -- đã dùng/chuyển tiếp số thuốc này rồi → không cho rút (tồn cuối sẽ âm)
    if coalesce(app_private._lot_final(t.to_unit_id::text, v_dst_per, t.drug, t.lot, t.exp), 0) < 0 then
      raise exception 'ERR_NEGATIVE: đơn vị nhận đã dùng số thuốc này trong kỳ % — huỷ phiếu sẽ làm tồn cuối âm. Sửa số bên nhận trước.', v_dst_per;
    end if;
  end if;

  return json_build_object('result', 'ok', 'type', t.type, 'period', t.period,
                           'rx_period', v_rx, 'was_confirmed', v_was_conf);
end $$;

-- ── 8) Cộng / trừ NGUYÊN TỬ cột Tỉnh cấp của đơn vị trực thuộc ───────────
create or replace function public.report_add_tinh(p_unit uuid, p_period text, p_drug text, p_lot text, p_exp text, p_delta numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare s public.app_sessions;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;
  if not app_private._tx_can(s, p_unit::text) then raise exception 'ERR_FORBIDDEN_UNIT'; end if;
  return coalesce(app_private._rep_add(p_unit::text, p_period, p_drug, p_lot, p_exp, 'tinh', p_delta, true), 0);
end $$;

-- ── 9) Admin sửa ngày chuyển / ngày nhận: chuyển số giữa 2 kỳ TRỌN 1 GIAO DỊCH ──
create or replace function public.transfer_move_date(p_id uuid, p_field text, p_date date)
returns json language plpgsql security definer set search_path = public as $$
declare
  s public.app_sessions; t public.transfers%rowtype;
  v_old text; v_new text; v_unit text; v_col text; v_cur numeric; v_neg text;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;
  if coalesce(s.role, '') <> 'admin' then raise exception 'ERR_FORBIDDEN: chỉ quản trị viên được sửa ngày phiếu'; end if;
  if p_field not in ('transfer_date', 'receive_date') then raise exception 'ERR_BAD_FIELD'; end if;
  if p_date is null or p_date > (now() at time zone 'Asia/Ho_Chi_Minh')::date then raise exception 'ERR_BAD_DATE: ngày ở tương lai'; end if;

  select * into t from public.transfers where id = p_id for update;
  if not found then raise exception 'ERR_NOT_FOUND'; end if;
  if t.status not in ('pending', 'confirmed') then
    return json_build_object('result', 'not_active', 'status', t.status);
  end if;

  if p_field = 'receive_date' then
    if t.status <> 'confirmed' or t.receive_date is null then raise exception 'ERR_NOT_RECEIVED: phiếu chưa có ngày nhận'; end if;
    if t.transfer_date is not null and p_date < t.transfer_date::date then raise exception 'ERR_BAD_DATE: ngày nhận trước ngày chuyển'; end if;
    v_old := app_private._period_of(t.receive_date::date, t.period);
    v_new := app_private._period_of(p_date, t.period);
    v_unit := t.to_unit_id::text;
    v_col := case t.type when 'dc2_to_dc' then 'dc' when 'dc3_province' then 'ntk' else null end;   -- Tổ CL: ngày nhận chỉ là ghi chú
    if v_unit is null then v_col := null; end if;                                                    -- nơi nhận ngoài hệ thống
  else
    if t.receive_date is not null and p_date > t.receive_date::date then raise exception 'ERR_BAD_DATE: ngày chuyển sau ngày nhận'; end if;
    v_old := t.period;                                   -- số xuất nằm ở kỳ của phiếu
    v_new := app_private._period_of(p_date, t.period);
    if t.type = 'dc3_to_tinh' then v_unit := t.to_unit_id::text; v_col := 'tinh';
    elsif t.type = 'dc2_to_dc' then v_unit := t.from_unit_id::text; v_col := 'dc2';
    else v_unit := t.from_unit_id::text; v_col := 'dc3';
    end if;
  end if;

  if v_col is not null and v_old <> v_new then
    if v_unit is null then raise exception 'ERR_NO_UNIT'; end if;
    -- kỳ cũ phải thật sự đang giữ số của phiếu (không kẹp về 0 để che lệch)
    execute format('select coalesce(sum(%I), 0) from public.reports
                     where unit_id::text = $1 and period = $2 and drug = $3 and lot = $4 and coalesce(exp, '''') = $5', v_col)
      into v_cur using v_unit, v_old, t.drug, t.lot, coalesce(t.exp, '');
    if v_cur < coalesce(t.qty, 0) then
      raise exception 'ERR_MISMATCH: kỳ % chỉ có % ở cột % (phiếu %) — số liệu và phiếu đang lệch, cần đối chiếu trước', v_old, v_cur, v_col, t.qty;
    end if;
    perform app_private._rep_add(v_unit, v_old, t.drug, t.lot, t.exp, v_col, -coalesce(t.qty, 0), false);
    perform app_private._rep_add(v_unit, v_new, t.drug, t.lot, t.exp, v_col,  coalesce(t.qty, 0), true);
    -- không để tồn cuối âm ở 2 kỳ vừa đổi
    select string_agg(r.period, ', ') into v_neg from public.reports r
     where r.unit_id::text = v_unit and r.period in (v_old, v_new) and r.drug = t.drug and r.lot = t.lot
       and coalesce(r.exp, '') = coalesce(t.exp, '')
       and coalesce(r.open,0)+coalesce(r.tinh,0)+coalesce(r.ntk,0)+coalesce(r.dc,0)+coalesce(r.n4,0)
           -coalesce(r.sd,0)-coalesce(r.dc2,0)-coalesce(r.dc3,0)-coalesce(r.hh,0) < 0;
    if v_neg is not null then raise exception 'ERR_NEGATIVE: tồn cuối sẽ âm ở kỳ %', v_neg; end if;
  end if;

  if p_field = 'receive_date' then
    update public.transfers set receive_date = p_date where id = p_id;
  else
    update public.transfers set transfer_date = p_date, period = v_new where id = p_id;
  end if;
  return json_build_object('result', 'ok', 'old_period', v_old, 'new_period', v_new, 'col', v_col, 'unit_id', v_unit,
                           'moved', (v_col is not null and v_old <> v_new));
end $$;

-- ── 10) Ghi vào kỳ ĐÃ CHỐT từ trình duyệt: ghi nhật ký (bật strict_period_lock để chặn hẳn) ──
--   Chỉ xét tài khoản KHÔNG phải admin ghi thẳng qua REST và có ĐỔI SỐ (không tính đổi cờ locked).
--   Hàm máy chủ (lan tồn đầu, xác nhận/huỷ phiếu) chạy quyền chủ sở hữu → không bị ảnh hưởng.
create or replace function public.trg_reports_period_lock()
returns trigger language plpgsql set search_path = public
as $$
declare s public.app_sessions; v_per text; v_unit text; v_chg boolean;
begin
  if current_user not in ('anon', 'authenticated') then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;
  s := app_private._app_sess();
  if s.token is null or coalesce(s.role, '') = 'admin' then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;

  if TG_OP = 'UPDATE' then
    v_per := OLD.period; v_unit := OLD.unit_id::text;
    v_chg := (NEW.open, NEW.tinh, NEW.ntk, NEW.dc, NEW.n4, NEW.sd, NEW.dc2, NEW.dc3, NEW.hh, NEW.period, NEW.unit_id, NEW.drug, NEW.lot, NEW.exp)
             is distinct from
             (OLD.open, OLD.tinh, OLD.ntk, OLD.dc, OLD.n4, OLD.sd, OLD.dc2, OLD.dc3, OLD.hh, OLD.period, OLD.unit_id, OLD.drug, OLD.lot, OLD.exp);
  elsif TG_OP = 'DELETE' then
    v_per := OLD.period; v_unit := OLD.unit_id::text; v_chg := true;
  else
    v_per := NEW.period; v_unit := NEW.unit_id::text;
    v_chg := (coalesce(NEW.open,0), coalesce(NEW.tinh,0), coalesce(NEW.ntk,0), coalesce(NEW.dc,0), coalesce(NEW.n4,0),
              coalesce(NEW.sd,0), coalesce(NEW.dc2,0), coalesce(NEW.dc3,0), coalesce(NEW.hh,0))
             is distinct from (0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric);
  end if;

  if v_chg and app_private._period_locked(v_per, v_unit) then
    perform app_private._log_violation(s, 'reports', 'LOCKED_' || TG_OP, v_unit, v_per || ' | ' ||
      coalesce(case when TG_OP = 'DELETE' then OLD.drug else NEW.drug end, '') || ' | ' ||
      coalesce(case when TG_OP = 'DELETE' then OLD.lot else NEW.lot end, ''));
    if app_private._cfg_on('strict_period_lock') then
      raise exception 'ERR_LOCKED: kỳ % của đơn vị đã chốt — không sửa được số liệu. Nhờ quản trị viên mở kỳ.', v_per;
    end if;
  end if;
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end $$;

drop trigger if exists trg_reports_period_lock on public.reports;
create trigger trg_reports_period_lock
  before insert or update or delete on public.reports
  for each row execute function public.trg_reports_period_lock();

-- ── 11) Khoá kỳ cũ ghi theo TÊN → thêm khoá theo unit_id ─────────────────
--   Tên duy nhất: thêm cho đúng đơn vị đó. Tên trùng nhiều đơn vị: chỉ thêm cho đơn vị có dòng
--   báo cáo kỳ đó đang mang cờ locked = true (đơn vị thật sự đã chốt). Không xoá khoá cũ.
do $$
declare lp jsonb; add jsonb := '{}'::jsonb; k text; v jsonb; m text[]; n_units int; r record;
begin
  select st.value::jsonb into lp from public.settings st where st.key = 'lockedPeriods';
  if lp is null or jsonb_typeof(lp) <> 'object' then return; end if;
  for k, v in select * from jsonb_each(lp) loop
    m := regexp_match(k, '^(\d{4}-(?:\d{2}|Q[1-4]))_(.+)$');
    continue when m is null;
    continue when m[2] = 'bvph' or m[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    continue when v is null or v = 'null'::jsonb or v = 'false'::jsonb;
    select count(*) into n_units from public.units u where u.name = m[2];
    for r in
      select u.id::text as id from public.units u
       where u.name = m[2]
         and (n_units = 1 or exists (select 1 from public.reports rp
                                      where rp.unit_id = u.id and rp.period = m[1] and rp.locked is true))
    loop
      if not (lp ? (m[1] || '_' || r.id)) then add := add || jsonb_build_object(m[1] || '_' || r.id, v); end if;
    end loop;
  end loop;
  if add <> '{}'::jsonb then
    update public.settings set value = (value::jsonb || add) where key = 'lockedPeriods';
    raise notice 'Đã thêm % khoá kỳ theo mã đơn vị', (select count(*) from jsonb_object_keys(add));
  end if;
end $$;

-- ── Quyền ────────────────────────────────────────────────────────────────
grant execute on function public.transfer_reject(uuid)                              to anon, authenticated;
grant execute on function public.transfer_cancel(uuid)                              to anon, authenticated;
grant execute on function public.report_add_tinh(uuid, text, text, text, text, numeric) to anon, authenticated;
grant execute on function public.transfer_move_date(uuid, text, date)               to anon, authenticated;

notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════
-- KIỂM TRA SAU KHI CHẠY (chỉ ĐỌC — chạy từng câu):
--   1) Hàm mới đã có (4 dòng):
--      select proname from pg_proc where proname in
--        ('transfer_move_date','report_add_tinh','trg_reports_period_lock','_period_locked');
--   2) Lô đang có tồn cuối ÂM (cần sửa tại nguồn — sau bản này số âm sẽ lan đúng sang kỳ sau):
--      select u.name, r.period, r.drug, r.lot,
--             coalesce(r.open,0)+coalesce(r.tinh,0)+coalesce(r.ntk,0)+coalesce(r.dc,0)+coalesce(r.n4,0)
--             -coalesce(r.sd,0)-coalesce(r.dc2,0)-coalesce(r.dc3,0)-coalesce(r.hh,0) as ton_cuoi
--        from public.reports r join public.units u on u.id = r.unit_id
--       where coalesce(r.open,0)+coalesce(r.tinh,0)+coalesce(r.ntk,0)+coalesce(r.dc,0)+coalesce(r.n4,0)
--             -coalesce(r.sd,0)-coalesce(r.dc2,0)-coalesce(r.dc3,0)-coalesce(r.hh,0) < 0
--       order by r.period, u.name;
--   3) Lô "mồ côi": kỳ tháng có tồn đầu ≠ 0 nhưng tháng trước (đơn vị có số liệu) không có lô đó:
--      select u.name, n.period, n.drug, n.lot, n.open
--        from public.reports n join public.units u on u.id = n.unit_id
--       where n.period ~ '^\d{4}-\d{2}$' and coalesce(n.open,0) <> 0
--         and exists (select 1 from public.reports p where p.unit_id = n.unit_id
--                      and p.period = to_char(to_date(n.period||'-01','YYYY-MM-DD') - interval '1 month','YYYY-MM'))
--         and not exists (select 1 from public.reports p where p.unit_id = n.unit_id
--                      and p.period = to_char(to_date(n.period||'-01','YYYY-MM-DD') - interval '1 month','YYYY-MM')
--                      and p.drug = n.drug and p.lot = n.lot and coalesce(p.exp,'') = coalesce(n.exp,''))
--       order by n.period, u.name;
--      → Nếu danh sách đúng là số sai cần đưa về 0, bật tự sửa khi lan tồn đầu:
--        update public.app_config set value = 'on' where key = 'cascade_zero_orphan';
--   4) Ghi vào kỳ đã chốt (nhật ký — xem vài tuần trước khi bật chặn):
--      select at, user_id, target_unit, op, detail from public.security_violations
--       where op like 'LOCKED_%' order by at desc limit 50;
--      → Bật chặn hẳn:  update public.app_config set value = 'on'  where key = 'strict_period_lock';
--        Tắt lại:       update public.app_config set value = 'off' where key = 'strict_period_lock';
-- ═══════════════════════════════════════════════════════════════════════
