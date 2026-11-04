-- ═══════════════════════════════════════════════════════════════════════
-- 08_tai_khoan_an_toan.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
-- Yêu cầu: đã chạy 01 (bảng private.accounts, các hàm tài khoản), 02 và 07.
--
-- Sửa các lỗ hổng ở hàm tài khoản (giữ nguyên tên + tham số, app cũ vẫn chạy):
--  1. verify_login : tài khoản đã KHOÁ (status = 'locked') không đăng nhập được nữa
--                    (bản cũ chỉ xét cột active nên "Khoá tài khoản" không có tác dụng).
--  2. upsert_account:
--       • admin KHÔNG tự đổi vai trò / tự khoá chính mình (tránh tự mất quyền quản trị);
--       • khoá tài khoản → huỷ luôn các phiên đang mở của tài khoản đó;
--       • mật khẩu mới tối thiểu 8 ký tự.
--  3. change_password: mật khẩu mới tối thiểu 8 ký tự.
--  4. update_unit  : chỉ admin được đổi CẤP (utype) và TRẠNG THÁI của đơn vị.
--  5. update_my_profile (mới): mọi tài khoản tự sửa email / số điện thoại của mình.
-- ═══════════════════════════════════════════════════════════════════════

-- 1) Đăng nhập: chặn tài khoản đã khoá
create or replace function public.verify_login(p_user text, p_pass text)
returns table(user_id text, name text, role text, unit text, unit_id uuid, u_path text)
language sql security definer
set search_path to 'private', 'public', 'extensions'
as $function$
  select a.user_id, a.name, a.role, u.name, a.unit_id, u.path
    from private.accounts a
    left join public.units u on u.id = a.unit_id
   where a.user_id = p_user and a.active
     and coalesce(a.status, 'active') <> 'locked'
     and a.pass_hash = crypt(p_pass, a.pass_hash);
$function$;

-- 2) Tạo / sửa tài khoản
create or replace function public.upsert_account(p_actor text, p_actor_pass text, p_user text, p_name text,
  p_unit_id uuid, p_role text, p_new_pass text, p_email text default ''::text, p_phone text default ''::text,
  p_status text default 'active'::text)
returns text language plpgsql security definer
set search_path to 'private', 'public', 'extensions'
as $function$
declare a_role text; exists_row boolean; v_self boolean;
begin
  if not private._auth(p_actor, p_actor_pass) then return 'ERR_AUTH'; end if;
  if coalesce(p_new_pass, '') <> '' and length(p_new_pass) < 8 then return 'ERR_WEAK_PASS'; end if;
  select role into a_role from private._actor_ctx(p_actor);
  if a_role <> 'admin' then
    if p_role = 'admin' then return 'ERR_FORBIDDEN'; end if;
    if not private._can_manage(p_actor, p_unit_id) then return 'ERR_FORBIDDEN'; end if;
  end if;
  v_self := (p_user = p_actor);
  select exists(select 1 from private.accounts where user_id = p_user) into exists_row;
  if exists_row then
    if a_role <> 'admin' then
      if not private._can_manage(p_actor,
           (select unit_id from private.accounts where user_id = p_user))
      then return 'ERR_FORBIDDEN'; end if;
    end if;
    update private.accounts set
       name = p_name, unit_id = p_unit_id,
       -- admin đổi vai trò người KHÁC; không ai tự đổi vai trò của chính mình
       role = case when a_role = 'admin' and not v_self then coalesce(p_role, role) else role end,
       email = coalesce(p_email, email), phone = coalesce(p_phone, phone),
       -- không tự khoá chính mình
       status = case when v_self then status else coalesce(p_status, status) end,
       pass_hash = case when coalesce(p_new_pass, '') <> ''
                        then extensions.crypt(p_new_pass, extensions.gen_salt('bf'))
                        else pass_hash end
     where user_id = p_user;
    -- Khoá tài khoản → đăng xuất các phiên đang mở
    if not v_self and p_status = 'locked' then
      delete from public.app_sessions where user_id = p_user;
    end if;
    return 'OK';
  else
    if coalesce(p_new_pass, '') = '' then return 'ERR_EMPTY_PASS'; end if;
    insert into private.accounts(user_id, name, role, unit_id, pass_hash, email, phone, status, created_by)
      values(p_user, p_name, coalesce(p_role, 'don_vi'), p_unit_id,
             extensions.crypt(p_new_pass, extensions.gen_salt('bf')),
             coalesce(p_email, ''), coalesce(p_phone, ''), coalesce(p_status, 'active'), p_actor);
    return 'OK';
  end if;
exception
  when unique_violation then return 'ERR_DUP';
end $function$;

-- 3) Tự đổi mật khẩu
create or replace function public.change_password(p_actor text, p_actor_pass text, p_new_pass text)
returns text language plpgsql security definer
set search_path to 'private', 'public', 'extensions'
as $function$
begin
  if not private._auth(p_actor, p_actor_pass) then return 'ERR_AUTH'; end if;
  if coalesce(p_new_pass, '') = '' then return 'ERR_EMPTY_PASS'; end if;
  if length(p_new_pass) < 8 then return 'ERR_WEAK_PASS'; end if;
  update private.accounts set pass_hash = crypt(p_new_pass, gen_salt('bf'))
   where user_id = p_actor;
  return 'OK';
end $function$;

-- 4) Sửa đơn vị: chỉ admin đổi cấp / trạng thái
create or replace function public.update_unit(p_actor text, p_actor_pass text, p_id uuid, p_name text,
  p_utype text, p_mien text, p_tinh text, p_tinh_cu text, p_status text)
returns text language plpgsql security definer
set search_path to 'private', 'public', 'extensions'
as $function$
declare a_role text; v_admin boolean;
begin
  if not private._auth(p_actor, p_actor_pass) then return 'ERR_AUTH'; end if;
  select role into a_role from private._actor_ctx(p_actor);
  v_admin := (a_role = 'admin');
  if not v_admin then
    if not private._can_manage(p_actor, p_id) then return 'ERR_FORBIDDEN'; end if;
  end if;
  update public.units set
    name    = coalesce(p_name, name),
    utype   = case when v_admin then coalesce(p_utype, utype) else utype end,
    mien    = coalesce(p_mien, mien),
    tinh    = coalesce(p_tinh, tinh),
    tinh_cu = coalesce(p_tinh_cu, tinh_cu),
    status  = case when v_admin then coalesce(p_status, status) else status end
   where id = p_id;
  return 'OK';
end $function$;

-- 5) Tự sửa email / số điện thoại của chính mình (mọi cấp)
create or replace function public.update_my_profile(p_actor text, p_actor_pass text, p_email text, p_phone text)
returns text language plpgsql security definer
set search_path to 'private', 'public', 'extensions'
as $function$
begin
  if not private._auth(p_actor, p_actor_pass) then return 'ERR_AUTH'; end if;
  update private.accounts set
     email = coalesce(p_email, email),
     phone = coalesce(p_phone, phone)
   where user_id = p_actor;
  return 'OK';
end $function$;

grant execute on function public.update_my_profile(text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- KIỂM TRA (chỉ đọc):
--   select proname from pg_proc where proname = 'update_my_profile';
--   select count(*) from pg_proc where proname = 'verify_login' and prosrc like '%locked%';   -- = 1
