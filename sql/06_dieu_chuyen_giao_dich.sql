-- ═══════════════════════════════════════════════════════════════════════
-- 06_dieu_chuyen_giao_dich.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
-- Yêu cầu: đã chạy 01, 02, 05.
--
-- XÁC NHẬN / TỪ CHỐI / HUỶ PHIẾU ĐIỀU CHUYỂN CHẠY TRỌN 1 GIAO DỊCH TRÊN MÁY CHỦ.
-- Trước đây trình duyệt gọi 3–5 lệnh rời (đổi trạng thái phiếu → đọc → sửa báo cáo).
-- Rớt mạng giữa chừng → phiếu đã "confirmed" mà kho bên nhận chưa được cộng
-- (bấm lại bị chặn vì phiếu không còn pending) → thuốc mất khỏi hệ thống.
-- Nay mỗi thao tác là 1 hàm: hoặc xong hết, hoặc không thay đổi gì.
--
-- Quy tắc ghi số GIỮ NGUYÊN như app hiện tại:
--   dc2_to_dc    (Xuất ĐC, đơn vị → đơn vị cùng tỉnh): bên gửi dc2 (kỳ ngày chuyển);
--                bên nhận dc khi XÁC NHẬN (kỳ ngày nhận).
--   dc3_province (Xuất tỉnh khác): bên gửi dc3 (kỳ ngày chuyển);
--                bên nhận ntk khi XÁC NHẬN (kỳ ngày nhận).
--   dc3_to_tinh  (Xuất Tổ CL, kho → đơn vị trực thuộc): bên nhận tinh được cộng NGAY lúc xuất;
--                xác nhận chỉ đổi trạng thái; Xuất TCL của kho = Σ tinh (app tự tính lại).
--   Trừ (từ chối / huỷ) không xuống dưới 0 — giống app.
--
-- App mới gọi các hàm này qua /rest/v1/rpc/...; nếu CHƯA chạy file này app tự quay về
-- cách cũ, nên có thể cập nhật app trước hay chạy SQL trước đều được.
-- ═══════════════════════════════════════════════════════════════════════

-- Kỳ báo cáo chứa 1 ngày, theo kiểu kỳ tham chiếu (quý ⇔ Hàng 1, tháng ⇔ Hàng 2)
create or replace function app_private._period_of(p_date date, p_ref text)
returns text language sql immutable as $$
  select case when coalesce(p_ref, '') ~ '^\d{4}-Q[1-4]$'
              then to_char(p_date, 'YYYY') || '-Q' || to_char(p_date, 'Q')
              else to_char(p_date, 'YYYY-MM') end;
$$;

-- Cộng (p_delta > 0) / trừ (p_delta < 0, không xuống dưới 0) một cột của 1 dòng reports.
-- p_create = true: chưa có dòng thì tạo (chỉ khi cộng).
-- Trả về giá trị mới của cột (null nếu không có dòng nào).
create or replace function app_private._rep_add(
  p_unit text, p_period text, p_drug text, p_lot text, p_exp text,
  p_col text, p_delta numeric, p_create boolean)
returns numeric
language plpgsql security definer set search_path = public
as $$
declare
  v_pl text := case when p_period ~ '^\d{4}-Q[1-4]$' then 'h1' else 'h2' end;
  v_pt text := case when p_period ~ '^\d{4}-Q[1-4]$' then 'quarter' else 'month' end;
  v_new numeric;
begin
  if p_col not in ('tinh', 'ntk', 'dc', 'dc2', 'dc3') then raise exception 'ERR_BAD_COL %', p_col; end if;
  if p_unit is null or p_period is null then return null; end if;

  execute format(
    'update public.reports set %1$I = greatest(0, coalesce(%1$I, 0) + $1)
      where unit_id::text = $2 and period = $3 and coalesce(phan_loai, ''h2'') = $4
        and drug = $5 and lot = $6 and coalesce(exp, '''') = $7
      returning %1$I', p_col)
    into v_new
    using p_delta, p_unit, p_period, v_pl, p_drug, p_lot, coalesce(p_exp, '');

  if v_new is null and p_create and p_delta > 0 then
    insert into public.reports(unit_id, period, phan_loai, period_type, drug, lot, exp,
                               open, tinh, ntk, dc, n4, sd, dc2, dc3, hh, locked)
    values (p_unit::uuid, p_period, v_pl, v_pt, p_drug, p_lot, coalesce(p_exp, ''),
            0, 0, 0, 0, 0, 0, 0, 0, 0, false);
    execute format(
      'update public.reports set %1$I = $1
        where unit_id::text = $2 and period = $3 and coalesce(phan_loai, ''h2'') = $4
          and drug = $5 and lot = $6 and coalesce(exp, '''') = $7
        returning %1$I', p_col)
      into v_new
      using p_delta, p_unit, p_period, v_pl, p_drug, p_lot, coalesce(p_exp, '');
  end if;
  return v_new;
end $$;

-- Quyền: admin, hoặc đơn vị trong nhánh của phiên (mình + con cháu)
create or replace function app_private._tx_can(s public.app_sessions, p_unit text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(s.role, '') = 'admin'
      or app_private._unit_in_scope(p_unit, s.unit_id, s.u_path);
$$;

-- ── XÁC NHẬN đã nhận ────────────────────────────────────────────────────
create or replace function public.transfer_confirm(p_id uuid, p_receive_date date)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  s public.app_sessions;
  t public.transfers%rowtype;
  v_per text; v_col text; v_val numeric;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;

  select * into t from public.transfers where id = p_id for update;
  if not found then raise exception 'ERR_NOT_FOUND'; end if;
  if not app_private._tx_can(s, t.to_unit_id::text) then raise exception 'ERR_FORBIDDEN_UNIT'; end if;
  if t.status is distinct from 'pending' then
    return json_build_object('result', 'not_pending', 'status', t.status);
  end if;
  if p_receive_date is null or p_receive_date > (now() at time zone 'Asia/Ho_Chi_Minh')::date then
    raise exception 'ERR_BAD_DATE: ngày nhận không hợp lệ / ở tương lai';
  end if;
  if t.transfer_date is not null and p_receive_date < t.transfer_date::date then
    raise exception 'ERR_BAD_DATE: ngày nhận trước ngày chuyển';
  end if;

  update public.transfers
     set status = 'confirmed', receive_date = p_receive_date,
         notif_for = t.from_unit, notif_read = false
   where id = p_id;

  v_per := app_private._period_of(p_receive_date, t.period);
  v_col := case t.type when 'dc2_to_dc' then 'dc' when 'dc3_province' then 'ntk' else null end;
  if v_col is not null then
    if t.to_unit_id is null then raise exception 'ERR_NO_UNIT: phiếu thiếu đơn vị nhận'; end if;
    v_val := app_private._rep_add(t.to_unit_id::text, v_per, t.drug, t.lot, t.exp, v_col, coalesce(t.qty, 0), true);
  end if;

  return json_build_object('result', 'ok', 'type', t.type, 'period', v_per,
                           'col', v_col, 'value', v_val, 'unit_id', t.to_unit_id);
end $$;

-- ── TỪ CHỐI (chỉ phiếu đang chờ) — trả số về bên gửi ─────────────────────
create or replace function public.transfer_reject(p_id uuid)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  s public.app_sessions;
  t public.transfers%rowtype;
  v_per text;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;

  select * into t from public.transfers where id = p_id for update;
  if not found then raise exception 'ERR_NOT_FOUND'; end if;
  if not app_private._tx_can(s, t.to_unit_id::text) then raise exception 'ERR_FORBIDDEN_UNIT'; end if;
  if t.status is distinct from 'pending' then
    return json_build_object('result', 'not_pending', 'status', t.status);
  end if;

  update public.transfers
     set status = 'rejected', notif_for = t.from_unit, notif_read = false
   where id = p_id;

  v_per := t.period;
  if t.type = 'dc2_to_dc' then
    perform app_private._rep_add(t.from_unit_id::text, v_per, t.drug, t.lot, t.exp, 'dc2', -coalesce(t.qty, 0), false);
  elsif t.type = 'dc3_province' then
    perform app_private._rep_add(t.from_unit_id::text, v_per, t.drug, t.lot, t.exp, 'dc3', -coalesce(t.qty, 0), false);
  elsif t.type = 'dc3_to_tinh' then
    perform app_private._rep_add(t.to_unit_id::text, v_per, t.drug, t.lot, t.exp, 'tinh', -coalesce(t.qty, 0), false);
  end if;

  return json_build_object('result', 'ok', 'type', t.type, 'period', v_per);
end $$;

-- ── HUỶ phiếu (chờ hoặc đã nhận) — hoàn nguyên cả 2 bên ──────────────────
create or replace function public.transfer_cancel(p_id uuid)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  s public.app_sessions;
  t public.transfers%rowtype;
  v_was_conf boolean; v_rx text; v_dst_col text; v_dst_per text;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;

  select * into t from public.transfers where id = p_id for update;
  if not found then raise exception 'ERR_NOT_FOUND'; end if;
  if not (app_private._tx_can(s, t.from_unit_id::text) or app_private._tx_can(s, t.to_unit_id::text)) then
    raise exception 'ERR_FORBIDDEN_UNIT';
  end if;
  if t.status not in ('pending', 'confirmed') then
    return json_build_object('result', 'not_active', 'status', t.status);
  end if;
  v_was_conf := (t.status = 'confirmed');

  update public.transfers
     set status = 'cancelled', notif_for = t.to_unit, notif_read = false
   where id = p_id;

  -- thông báo cho bên gửi (giống app)
  insert into public.transfers(period, from_unit, to_unit, from_unit_id, to_unit_id,
                               drug, lot, exp, qty, phan_loai, type, status, notif_for, notif_read)
  values (t.period, t.from_unit, t.to_unit, t.from_unit_id, t.to_unit_id,
          t.drug, t.lot, coalesce(t.exp, ''), t.qty, t.phan_loai, 'cancel_notif', 'cancelled', t.from_unit, false);

  -- bên gửi
  if t.type = 'dc2_to_dc' then
    perform app_private._rep_add(t.from_unit_id::text, t.period, t.drug, t.lot, t.exp, 'dc2', -coalesce(t.qty, 0), false);
  elsif t.type = 'dc3_province' then
    perform app_private._rep_add(t.from_unit_id::text, t.period, t.drug, t.lot, t.exp, 'dc3', -coalesce(t.qty, 0), false);
  end if;

  -- bên nhận
  v_rx := case when t.receive_date is not null then app_private._period_of(t.receive_date::date, t.period) else t.period end;
  if t.type = 'dc3_to_tinh' then
    v_dst_col := 'tinh'; v_dst_per := t.period;
  elsif v_was_conf and t.type = 'dc2_to_dc' then
    v_dst_col := 'dc'; v_dst_per := v_rx;
  elsif v_was_conf and t.type = 'dc3_province' then
    v_dst_col := 'ntk'; v_dst_per := v_rx;
  end if;
  if v_dst_col is not null then
    perform app_private._rep_add(t.to_unit_id::text, v_dst_per, t.drug, t.lot, t.exp, v_dst_col, -coalesce(t.qty, 0), false);
  end if;

  return json_build_object('result', 'ok', 'type', t.type, 'period', t.period,
                           'rx_period', v_rx, 'was_confirmed', v_was_conf);
end $$;

-- Hàm nội bộ: không mở cho trình duyệt gọi trực tiếp
revoke all on function app_private._rep_add(text, text, text, text, text, text, numeric, boolean) from public, anon, authenticated;
grant execute on function app_private._period_of(date, text) to anon, authenticated;
grant execute on function app_private._tx_can(public.app_sessions, text) to anon, authenticated;

-- RPC cho app (tự kiểm tra phiên + quyền bên trong)
grant execute on function public.transfer_confirm(uuid, date) to anon, authenticated;
grant execute on function public.transfer_reject(uuid)        to anon, authenticated;
grant execute on function public.transfer_cancel(uuid)        to anon, authenticated;

-- Báo PostgREST nạp lại danh sách hàm
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════
-- KIỂM TRA SAU KHI CHẠY (chạy từng câu, chỉ ĐỌC):
--   1) 3 hàm đã có:
--      select proname from pg_proc where proname in ('transfer_confirm','transfer_reject','transfer_cancel');
--   2) Kiểu cột khớp giả định (id, from_unit_id, to_unit_id là uuid; receive_date là date):
--      select column_name, data_type from information_schema.columns
--       where table_schema='public' and table_name='transfers'
--         and column_name in ('id','from_unit_id','to_unit_id','receive_date','transfer_date','qty');
--      select column_name, data_type from information_schema.columns
--       where table_schema='public' and table_name='reports' and column_name='unit_id';
--   3) Gọi thử khi chưa đăng nhập phải báo ERR_SESSION (không thay đổi gì):
--      select public.transfer_confirm('00000000-0000-0000-0000-000000000000', current_date);
-- ═══════════════════════════════════════════════════════════════════════
