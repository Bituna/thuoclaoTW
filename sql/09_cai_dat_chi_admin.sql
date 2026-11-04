-- ═══════════════════════════════════════════════════════════════════════
-- 09_cai_dat_chi_admin.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
-- Yêu cầu: đã chạy 02, 04 và 07.
--
-- Các cài đặt DÙNG CHUNG TOÀN QUỐC trong bảng settings chỉ admin được ghi:
--   threshold (ngưỡng cảnh báo), regions (cấu hình miền), province_names (tên tỉnh hiển thị),
--   region_merges (gộp miền), unit_groups (gom đơn vị).
-- Trước đây mọi tài khoản đã đăng nhập đều ghi được (vd. 1 tỉnh đổi ngưỡng cảnh báo của cả nước),
-- và settings_merge chạy quyền chủ sở hữu nên còn lọt qua trigger kiểm tra.
-- Các khoá khác (khoá kỳ, dòng đã xoá, thông tin đơn vị unit_info...) giữ nguyên như cũ.
--
-- File này dựng lại 2 hàm (bản ở 04 và 07) và chỉ THÊM đoạn kiểm tra admin.
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app_private._admin_setting_keys()
returns text[] language sql immutable as $$
  select array['threshold', 'regions', 'province_names', 'region_merges', 'unit_groups']::text[];
$$;
grant execute on function app_private._admin_setting_keys() to anon, authenticated;

-- 1) Trigger kiểm tra ghi (bản 04 + kiểm tra khoá admin cho settings)
create or replace function public.trg_sec_guard()
returns trigger language plpgsql set search_path = public
as $$
declare s public.app_sessions; v_strict boolean; tgt text; src text; k text;
        is_admin boolean; has_scope boolean;
begin
  if current_user not in ('anon', 'authenticated') then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;

  s := app_private._app_sess();
  if s.token is null then
    raise exception 'ERR_SESSION: cần đăng nhập để ghi dữ liệu (%)', TG_TABLE_NAME;
  end if;

  is_admin  := coalesce(s.role, '') = 'admin';
  has_scope := s.unit_id is not null or coalesce(s.u_path, '') <> '';

  -- ── settings.ACCOUNTS: chỉ admin được xoá; không ai được ghi mới/sửa qua REST
  if TG_TABLE_NAME = 'settings' then
    k := case when TG_OP = 'DELETE' then OLD.key::text else NEW.key::text end;
    if k = 'ACCOUNTS' or (TG_OP = 'UPDATE' and OLD.key::text = 'ACCOUNTS') then
      if TG_OP <> 'DELETE' or not is_admin then
        raise exception 'ERR_FORBIDDEN: không được ghi danh sách tài khoản qua settings';
      end if;
    end if;
    -- Cấu hình dùng chung toàn quốc: chỉ admin được ghi / xoá (sql/09)
    if (k = any(app_private._admin_setting_keys())
        or (TG_OP = 'UPDATE' and OLD.key::text = any(app_private._admin_setting_keys())))
       and not is_admin then
      raise exception 'ERR_FORBIDDEN: chỉ quản trị viên được thay đổi cài đặt "%"', k;
    end if;
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;

  if is_admin then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;

  v_strict := app_private._strict_on();

  -- ── units: chỉ sửa qua RPC dành cho admin
  if TG_TABLE_NAME = 'units' then
    raise exception 'ERR_FORBIDDEN: chỉ admin được sửa cây đơn vị';
  end if;

  -- ── reports: giữ nguyên logic bản 02
  if TG_TABLE_NAME = 'reports' then
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

  -- ── patients: xoá ngoài phạm vi → chặn luôn; thêm/sửa ngoài phạm vi → nhật ký/strict
  if TG_TABLE_NAME = 'patients' then
    if TG_OP in ('UPDATE', 'DELETE') then
      src := OLD.unit::text;
      if not app_private._unit_name_in_scope(src, s.unit_id, s.u_path) then
        perform app_private._log_violation(s, TG_TABLE_NAME, TG_OP, src, 'patient ' || coalesce(OLD.id::text, ''));
        -- Chặn ngay khi tên là 1 đơn vị CÓ THẬT ngoài phạm vi; tên lạ (không khớp units) chỉ ghi nhật ký
        if (TG_OP = 'DELETE' and has_scope
            and exists (select 1 from public.units u where u.name = src)) or v_strict then
          raise exception 'ERR_FORBIDDEN_UNIT: không có quyền % bệnh nhân của đơn vị này', lower(TG_OP);
        end if;
      end if;
    end if;
    if TG_OP in ('INSERT', 'UPDATE') then
      tgt := NEW.unit::text;
      if not app_private._unit_name_in_scope(tgt, s.unit_id, s.u_path) then
        perform app_private._log_violation(s, TG_TABLE_NAME, TG_OP, tgt, 'patient ' || coalesce(NEW.id::text, ''));
        if v_strict then raise exception 'ERR_FORBIDDEN_UNIT: không có quyền ghi bệnh nhân của đơn vị này'; end if;
      end if;
    end if;
  end if;

  -- ── cap_phat: ngoài phạm vi → nhật ký/strict
  if TG_TABLE_NAME = 'cap_phat' then
    if TG_OP in ('UPDATE', 'DELETE') then
      src := OLD.unit::text;
      if not app_private._unit_name_in_scope(src, s.unit_id, s.u_path) then
        perform app_private._log_violation(s, TG_TABLE_NAME, TG_OP, src, OLD.drug || ' | ' || OLD.lot || ' | ' || OLD.bc_month);
        if v_strict then raise exception 'ERR_FORBIDDEN_UNIT: không có quyền ghi cấp phát của đơn vị này'; end if;
      end if;
    end if;
    if TG_OP in ('INSERT', 'UPDATE') then
      tgt := NEW.unit::text;
      if not app_private._unit_name_in_scope(tgt, s.unit_id, s.u_path) then
        perform app_private._log_violation(s, TG_TABLE_NAME, TG_OP, tgt, NEW.drug || ' | ' || NEW.lot || ' | ' || NEW.bc_month);
        if v_strict then raise exception 'ERR_FORBIDDEN_UNIT: không có quyền ghi cấp phát của đơn vị này'; end if;
      end if;
    end if;
  end if;

  -- ── catalog: xoá danh mục → nhật ký/strict
  if TG_TABLE_NAME = 'catalog' and TG_OP = 'DELETE' then
    perform app_private._log_violation(s, TG_TABLE_NAME, TG_OP, null, OLD.drug || ' | ' || OLD.lot);
    if v_strict then raise exception 'ERR_FORBIDDEN: chỉ admin được xoá danh mục thuốc'; end if;
  end if;

  return case when TG_OP = 'DELETE' then OLD else NEW end;
end $$;

-- 2) settings_merge (bản 07 + kiểm tra khoá admin)
create or replace function public.settings_merge(p_key text, p_set jsonb, p_del text[])
returns void
language plpgsql security definer
set search_path = public
as $$
declare s public.app_sessions;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION: cần đăng nhập để ghi cài đặt'; end if;
  if p_key = any(app_private._admin_setting_keys()) and coalesce(s.role, '') <> 'admin' then
    raise exception 'ERR_FORBIDDEN: chỉ quản trị viên được thay đổi cài đặt "%"', p_key;
  end if;
  insert into public.settings(key, value) values (p_key, coalesce(p_set, '{}'::jsonb))
  on conflict (key) do update
    set value = (coalesce(public.settings.value, '{}'::jsonb) - coalesce(p_del, '{}'::text[]))
                || coalesce(p_set, '{}'::jsonb);
end $$;
grant execute on function public.settings_merge(text, jsonb, text[]) to anon, authenticated;

notify pgrst, 'reload schema';

-- KIỂM TRA (chỉ đọc):
--   select prosrc like '%_admin_setting_keys%' from pg_proc where proname in ('trg_sec_guard','settings_merge');  -- 2 dòng true
