-- ═══════════════════════════════════════════════════════════════════════
-- 03_quan_ly_mien.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
--
-- Dùng cho trang "Quản lý miền" (thêm / đổi tên / xoá miền, chuyển tỉnh sang miền khác):
--  1) Gắn mã miền (cột mien) cho các node Kho miền đang để trống, suy từ slug
--     (mien-bac → bac, mien-nam → nam…). Nhờ vậy miền mới chưa có đơn vị vẫn hiện.
--  2) Hàm move_units_region: chuyển các đơn vị của 1 số tỉnh từ Kho miền này sang
--     Kho miền khác — đổi đơn vị cha, viết lại path cả nhánh con, đổi cột mien.
--     Dữ liệu báo cáo/phiếu gắn theo unit_id nên ĐI THEO ĐƠN VỊ, không mất.
--     Chỉ tài khoản admin được gọi. Toàn bộ chạy trong 1 giao dịch.
--
-- Yêu cầu: đã chạy 01_schema_da_tinh.sql (verify_login, bảng units) và 02.
-- ═══════════════════════════════════════════════════════════════════════

-- 1) Mã miền cho node Kho miền
update public.units
   set mien = substring(slug from 6)
 where utype = 'kho_mien'
   and coalesce(mien, '') = ''
   and slug like 'mien-%';

-- 2) Chuyển đơn vị theo tỉnh sang miền khác
create or replace function public.move_units_region(
  p_actor text, p_actor_pass text,
  p_from text,            -- mã miền nguồn, vd 'nam'
  p_to   text,            -- mã miền đích, vd 'dong'
  p_tinh text[]           -- giá trị cột tinh của các đơn vị cần chuyển (đúng như trong units)
)
returns text
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v record; k_from public.units; k_to public.units; r public.units;
  old_p text; new_p text; n int := 0; t record;
begin
  select * into v from public.verify_login(p_actor, p_actor_pass) limit 1;
  if not found then return 'ERR_AUTH'; end if;
  if v.role::text <> 'admin' then return 'ERR_PERM'; end if;
  if p_from is null or p_to is null or p_from = p_to then return 'ERR_ARG'; end if;
  if p_tinh is null or array_length(p_tinh, 1) is null then return 'ERR_ARG'; end if;

  select * into k_from from public.units where utype = 'kho_mien' and mien = p_from limit 1;
  if not found then return 'ERR_NO_FROM'; end if;
  select * into k_to   from public.units where utype = 'kho_mien' and mien = p_to   limit 1;
  if not found then return 'ERR_NO_TO'; end if;

  for r in
    select * from public.units
     where parent_id = k_from.id and tinh = any(p_tinh)
     order by path
  loop
    old_p := r.path;
    new_p := k_to.path || '/' || r.slug;
    if exists (select 1 from public.units where path = new_p) then
      raise exception 'ERR_DUP_PATH %', new_p;
    end if;
    -- cả nhánh: path mới + mã miền mới
    update public.units
       set path = new_p || substring(path from length(old_p) + 1),
           mien = p_to
     where path = old_p or left(path, length(old_p) + 1) = old_p || '/';
    update public.units set parent_id = k_to.id where id = r.id;

    -- Bảng nào lưu sẵn u_path theo unit_id (tài khoản, phiên đăng nhập…) → viết lại luôn
    for t in
      select c1.table_schema, c1.table_name
        from information_schema.columns c1
        join information_schema.columns c2
          on c2.table_schema = c1.table_schema and c2.table_name = c1.table_name and c2.column_name = 'unit_id'
       where c1.column_name = 'u_path' and c1.table_schema = 'public'
         and exists (select 1 from information_schema.tables x
                      where x.table_schema = c1.table_schema and x.table_name = c1.table_name
                        and x.table_type = 'BASE TABLE')
    loop
      execute format(
        'update %I.%I set u_path = $1 || substring(u_path from length($2) + 1) where u_path = $2 or left(u_path, length($2) + 1) = $2 || ''/''',
        t.table_schema, t.table_name) using new_p, old_p;
    end loop;
    n := n + 1;
  end loop;

  return 'OK:' || n;
end $$;

revoke all on function public.move_units_region(text, text, text, text, text[]) from public;
grant execute on function public.move_units_region(text, text, text, text, text[]) to anon, authenticated;
