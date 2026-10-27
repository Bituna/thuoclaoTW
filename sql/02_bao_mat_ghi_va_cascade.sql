-- ═══════════════════════════════════════════════════════════════════════
-- 02_bao_mat_ghi_va_cascade.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
--
--  1) PHIÊN ĐĂNG NHẬP PHÍA MÁY CHỦ: đăng nhập xong app nhận 1 mã phiên (token)
--     và gửi kèm mọi request qua header `x-app-session`.
--  2) CHẶN GHI KHÔNG ĐĂNG NHẬP: mọi INSERT/UPDATE/DELETE trực tiếp qua REST
--     (vai trò anon/authenticated) vào các bảng dữ liệu phải có phiên hợp lệ.
--     → Người ngoài có anon key KHÔNG còn ghi/xoá được dữ liệu.
--     Bảng reports: kiểm tra thêm đơn vị được ghi (đơn vị mình + nhánh con).
--     Mặc định CHẾ ĐỘ GHI NHẬT KÝ (chỉ ghi vào security_violations, không chặn)
--     để kiểm tra không làm vỡ nghiệp vụ; sau ~1 tuần nếu bảng vi phạm trống
--     thì bật chặn hẳn bằng lệnh ở cuối file.
--  3) CHỐNG GHI ĐÈ KHI 2 NGƯỜI SỬA CÙNG 1 DÒNG (optimistic lock): cột
--     edited_at + base_edited_at trên reports.
--  4) LAN TỒN ĐẦU KỲ CHẠY TRÊN MÁY CHỦ: hàm cascade_opening_stock chạy trọn
--     trong 1 giao dịch (tắt trình duyệt giữa chừng không còn làm đứt chuỗi).
--
-- Yêu cầu: đã chạy 01_schema_da_tinh.sql (có hàm verify_login, bảng units).
-- ═══════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto with schema extensions;

-- ── Bảng cấu hình / phiên / nhật ký vi phạm (anon không đọc được) ─────────
create table if not exists public.app_config(
  key   text primary key,
  value text
);
insert into public.app_config(key, value) values ('strict_unit_write', 'off')
  on conflict (key) do nothing;

create table if not exists public.app_sessions(
  token      text primary key,
  user_id    text not null,
  role       text,
  unit_id    text,
  u_path     text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists app_sessions_exp_idx on public.app_sessions(expires_at);

create table if not exists public.security_violations(
  id          bigserial primary key,
  at          timestamptz not null default now(),
  user_id     text,
  role        text,
  sess_unit   text,
  tbl         text,
  op          text,
  target_unit text,
  detail      text
);

alter table public.app_config          enable row level security;
alter table public.app_sessions        enable row level security;
alter table public.security_violations enable row level security;
revoke all on public.app_config, public.app_sessions, public.security_violations from anon, authenticated;
revoke all on sequence public.security_violations_id_seq from anon, authenticated;

-- ── Tạo / kết thúc phiên ────────────────────────────────────────────────
create or replace function public.create_session(p_user text, p_pass text)
returns table(o_token text, o_expires_at timestamptz, o_role text)
language plpgsql security definer
set search_path = public, extensions
as $$
declare v record; t text; e timestamptz;
begin
  select * into v from public.verify_login(p_user, p_pass) limit 1;
  if not found then raise exception 'ERR_AUTH'; end if;
  delete from public.app_sessions s where s.expires_at < now();
  t := encode(extensions.gen_random_bytes(32), 'hex');
  e := now() + interval '12 hours';
  insert into public.app_sessions(token, user_id, role, unit_id, u_path, expires_at)
  values (t, v.user_id::text, v.role::text, v.unit_id::text, v.u_path::text, e);
  return query select t, e, v.role::text;
end $$;

create or replace function public.end_session(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from public.app_sessions where token = p_token;
$$;

grant execute on function public.create_session(text, text) to anon, authenticated;
grant execute on function public.end_session(text)         to anon, authenticated;

-- Hàm nội bộ đặt trong schema riêng (PostgREST KHÔNG mở ra ngoài như RPC)
create schema if not exists app_private;
grant usage on schema app_private to anon, authenticated;

-- Phiên của request hiện tại (đọc header x-app-session) — null nếu không có/hết hạn
create or replace function app_private._app_sess()
returns public.app_sessions
language plpgsql stable security definer set search_path = public
as $$
declare h text; s public.app_sessions;
begin
  begin
    h := current_setting('request.headers', true)::json ->> 'x-app-session';
  exception when others then h := null;
  end;
  if h is null or h = '' then return null; end if;
  select * into s from public.app_sessions where token = h and expires_at > now();
  return s;
end $$;
grant execute on function app_private._app_sess() to anon, authenticated;

-- Đơn vị target có thuộc nhánh (chính nó + con cháu) của phiên không
create or replace function app_private._unit_in_scope(p_target text, p_sess_unit text, p_sess_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_target is not null and (
    p_target = p_sess_unit
    or exists (
      select 1 from public.units u
      where u.id::text = p_target
        and coalesce(p_sess_path, '') <> ''
        and (
          u.path = p_sess_path
          or (left(u.path, length(p_sess_path)) = p_sess_path
              and (right(p_sess_path, 1) in ('/', '.')
                   or substr(u.path, length(p_sess_path) + 1, 1) in ('/', '.')))
        )
    )
  );
$$;
grant execute on function app_private._unit_in_scope(text, text, text) to anon, authenticated;

create or replace function app_private._log_violation(s public.app_sessions, p_tbl text, p_op text, p_unit text, p_detail text)
returns void language sql security definer set search_path = public as $$
  insert into public.security_violations(user_id, role, sess_unit, tbl, op, target_unit, detail)
  select s.user_id, s.role, s.unit_id, p_tbl, p_op, p_unit, p_detail
  where not exists (
    select 1 from public.security_violations v
    where v.user_id is not distinct from s.user_id and v.tbl = p_tbl and v.op = p_op
      and v.target_unit is not distinct from p_unit and v.at > now() - interval '1 hour'
  );
$$;
grant execute on function app_private._log_violation(public.app_sessions, text, text, text, text) to anon, authenticated;

create or replace function app_private._strict_on()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.app_config where key = 'strict_unit_write'), 'off') = 'on';
$$;
grant execute on function app_private._strict_on() to anon, authenticated;

-- ── Trigger bảo vệ ghi ──────────────────────────────────────────────────
-- KHÔNG security definer: current_user = vai trò thật của request.
--  • anon/authenticated (REST trực tiếp từ trình duyệt) → bắt buộc có phiên.
--  • Hàm RPC security definer / SQL Editor (postgres) → cho qua (hàm tự kiểm tra).
create or replace function public.trg_sec_guard()
returns trigger language plpgsql set search_path = public
as $$
declare s public.app_sessions; v_strict boolean; tgt text; src text;
begin
  if current_user not in ('anon', 'authenticated') then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;

  s := app_private._app_sess();
  if s.token is null then
    raise exception 'ERR_SESSION: cần đăng nhập để ghi dữ liệu (%)', TG_TABLE_NAME;
  end if;

  if TG_TABLE_NAME = 'reports' and coalesce(s.role, '') <> 'admin' then
    v_strict := app_private._strict_on();
    if TG_OP in ('INSERT', 'UPDATE') then
      tgt := NEW.unit_id::text;
      if not app_private._unit_in_scope(tgt, s.unit_id, s.u_path) then
        perform app_private._log_violation(s, TG_TABLE_NAME, TG_OP, tgt, NEW.drug || ' | ' || NEW.lot || ' | ' || NEW.period);
        if v_strict then raise exception 'ERR_FORBIDDEN_UNIT: không có quyền ghi đơn vị này'; end if;
      end if;
    end if;
    if TG_OP in ('UPDATE', 'DELETE') then
      src := OLD.unit_id::text;
      if not app_private._unit_in_scope(src, s.unit_id, s.u_path) then
        perform app_private._log_violation(s, TG_TABLE_NAME, TG_OP, src, OLD.drug || ' | ' || OLD.lot || ' | ' || OLD.period);
        if v_strict then raise exception 'ERR_FORBIDDEN_UNIT: không có quyền ghi đơn vị này'; end if;
      end if;
    end if;
  end if;

  return case when TG_OP = 'DELETE' then OLD else NEW end;
end $$;

do $$
declare t text;
begin
  foreach t in array array['reports', 'transfers', 'patients', 'cap_phat', 'catalog', 'settings', 'units'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_a_sec_guard on public.%I', t);
      execute format('create trigger trg_a_sec_guard before insert or update or delete on public.%I
                      for each row execute function public.trg_sec_guard()', t);
    end if;
  end loop;
end $$;

-- ── Chống ghi đè (optimistic lock) trên reports ────────────────────────
-- edited_at     : thời điểm số liệu NGƯỜI DÙNG NHẬP (tinh, ntk, dc, sd, dc2, dc3, hh, locked)
--                 đổi lần cuối. Lan tồn đầu (chỉ đổi cột open) KHÔNG làm đổi.
-- base_edited_at: app gửi kèm edited_at mà nó đã đọc. Nếu trên máy chủ đã khác
--                 → người khác vừa sửa dòng này → báo ERR_CONFLICT, không ghi đè.
alter table public.reports add column if not exists edited_at      timestamptz;
alter table public.reports add column if not exists base_edited_at timestamptz;
drop trigger if exists trg_b_edit_lock on public.reports;
update public.reports set edited_at = now() where edited_at is null;

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

  if (NEW.tinh, NEW.ntk, NEW.dc, NEW.sd, NEW.dc2, NEW.dc3, NEW.hh, NEW.locked)
     is distinct from (OLD.tinh, OLD.ntk, OLD.dc, OLD.sd, OLD.dc2, OLD.dc3, OLD.hh, OLD.locked) then
    NEW.edited_at := clock_timestamp();
  else
    NEW.edited_at := OLD.edited_at;
  end if;
  NEW.base_edited_at := null;
  return NEW;
end $$;

create trigger trg_b_edit_lock before insert or update on public.reports
  for each row execute function public.trg_reports_edit_lock();

-- ── Lan tồn đầu kỳ trên máy chủ ────────────────────────────────────────
-- Tồn đầu kỳ sau = max(0, tồn cuối kỳ trước) theo khóa unit_id + phân loại + thuốc + lô + hạn.
-- Giống hệt logic _cascadeOpeningStock cũ ở trình duyệt, nhưng chạy trọn 1 giao dịch.
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
             greatest(0, coalesce(r.open,0) + coalesce(r.tinh,0) + coalesce(r.ntk,0) + coalesce(r.dc,0)
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
                                 open, tinh, ntk, dc, sd, dc2, dc3, hh, locked)
      select c.unit_id, nxt, c.pl, c.pt, c.drug, c.lot, c.ex, c.fin, 0, 0, 0, 0, 0, 0, 0, false
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

-- PostgREST nạp lại schema để nhận cột/hàm mới
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════
-- SAU ~1 TUẦN: xem nhật ký vi phạm phạm vi đơn vị trên bảng reports
--   select * from public.security_violations order by at desc;
-- Nếu TRỐNG (hoặc chỉ là thao tác đáng ngờ thật) → bật CHẶN HẲN:
--   update public.app_config set value = 'on' where key = 'strict_unit_write';
-- Tắt lại nếu có sự cố:
--   update public.app_config set value = 'off' where key = 'strict_unit_write';
-- ═══════════════════════════════════════════════════════════════════════
