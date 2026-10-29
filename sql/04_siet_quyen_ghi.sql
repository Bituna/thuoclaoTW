-- ═══════════════════════════════════════════════════════════════════════
-- 04_siet_quyen_ghi.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
-- Yêu cầu: đã chạy 01 và 02.
--
-- Bản 02 chỉ kiểm tra "có đăng nhập" cho hầu hết các bảng; riêng reports mới
-- kiểm tra phạm vi đơn vị. File này mở rộng trigger trg_sec_guard:
--
--  CHẶN LUÔN (không phụ thuộc chế độ strict) với tài khoản KHÔNG phải admin:
--   • units    : mọi ghi trực tiếp qua REST (app chỉ sửa cây qua RPC create_unit/
--                update_unit/delete_unit… vốn tự kiểm tra quyền admin).
--   • settings : ghi dòng key = 'ACCOUNTS' (danh sách tài khoản cũ).
--   • patients : XOÁ bệnh nhân của đơn vị ngoài phạm vi mình quản lý
--                (vd. lệnh "xoá toàn bộ" gọi thẳng từ console).
--  GHI NHẬT KÝ (security_violations) và chỉ chặn khi strict_unit_write = 'on':
--   • patients : thêm/sửa bệnh nhân của đơn vị ngoài phạm vi.
--   • cap_phat : thêm/sửa/xoá dòng cấp phát cho đơn vị ngoài phạm vi.
--   • catalog  : xoá dòng danh mục thuốc.
--
--  Ngoài ra: gỡ trường mật khẩu "pass" khỏi dòng settings.ACCOUNTS cũ (nếu còn),
--  vì bảng settings đọc được bằng anon key công khai.
-- ═══════════════════════════════════════════════════════════════════════

-- Tên đơn vị (cột unit dạng chữ ở patients / cap_phat) có thuộc phạm vi phiên không
create or replace function app_private._unit_name_in_scope(p_name text, p_sess_unit text, p_sess_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_name is not null and exists (
    select 1 from public.units u
    where u.name = p_name
      and app_private._unit_in_scope(u.id::text, p_sess_unit, p_sess_path)
  );
$$;
grant execute on function app_private._unit_name_in_scope(text, text, text) to anon, authenticated;

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

-- Gắn lại trigger (phòng khi bảng mới được tạo sau lần chạy 02)
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

-- Gỡ trường mật khẩu khỏi settings.ACCOUNTS cũ (giữ tên/đơn vị để hiển thị)
do $$
declare v_type text;
begin
  select data_type into v_type from information_schema.columns
   where table_schema = 'public' and table_name = 'settings' and column_name = 'value';
  if v_type = 'jsonb' then
    update public.settings
       set value = (select coalesce(jsonb_agg(e - 'pass'), '[]'::jsonb) from jsonb_array_elements(value) e)
     where key = 'ACCOUNTS' and jsonb_typeof(value) = 'array';
  elsif v_type = 'json' then
    update public.settings
       set value = (select coalesce(jsonb_agg(e - 'pass'), '[]'::jsonb) from jsonb_array_elements(value::jsonb) e)::json
     where key = 'ACCOUNTS' and json_typeof(value) = 'array';
  end if;
end $$;

notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════
-- KIỂM TRA sau vài ngày:
--   select tbl, op, count(*) from public.security_violations group by 1, 2 order by 3 desc;
-- Nếu chỉ toàn thao tác đáng ngờ thật (không phải nghiệp vụ bình thường) → bật chặn hẳn:
--   update public.app_config set value = 'on' where key = 'strict_unit_write';
-- ═══════════════════════════════════════════════════════════════════════
