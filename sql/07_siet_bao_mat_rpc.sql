-- ═══════════════════════════════════════════════════════════════════════
-- 07_siet_bao_mat_rpc.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).
-- Yêu cầu: đã chạy 02 (phiên máy chủ). Xử lý các cảnh báo của Supabase Advisor:
--
--  1) list_accounts(): AI CŨNG GỌI ĐƯỢC (chỉ cần anon key trong mã nguồn trang) → lộ toàn bộ
--     tài khoản kèm EMAIL, SỐ ĐIỆN THOẠI. Nay: phải có phiên đăng nhập; email/điện thoại chỉ
--     trả cho admin hoặc tài khoản thuộc nhánh của người hỏi (tài khoản ngoài nhánh vẫn có
--     tên/đơn vị để app hiển thị, nhưng email/điện thoại để trống).
--  2) settings_merge(): AI CŨNG GHI ĐƯỢC bảng settings (khoá kỳ, ngưỡng...) vì hàm chạy quyền
--     chủ sở hữu nên bỏ qua trigger chặn ghi. Nay: phải có phiên đăng nhập.
--  3) Bảng reports có 2 chỉ mục UNIQUE trùng hệt nhau (uq_reports_row, ux_reports_key)
--     → bỏ 1 cái (ghi nhanh hơn, không đổi hành vi).
--  4) Cố định search_path cho 2 hàm còn thiếu.
--
-- App (bản sau PR #31) tự tải lại danh sách tài khoản NGAY SAU khi có phiên đăng nhập.
-- ═══════════════════════════════════════════════════════════════════════

-- 1) list_accounts — cần phiên; email/phone chỉ trong phạm vi
create or replace function public.list_accounts()
returns table(user_id text, name text, role text, unit text, unit_id uuid, u_path text,
              email text, phone text, status text, active boolean)
language plpgsql security definer
set search_path = private, public, extensions
as $$
declare s public.app_sessions;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION'; end if;
  return query
    select a.user_id, a.name, a.role, u.name, a.unit_id, u.path,
           case when ok.v then a.email else '' end,
           case when ok.v then a.phone else '' end,
           a.status, a.active
      from private.accounts a
      left join public.units u on u.id = a.unit_id
      cross join lateral (select coalesce(s.role, '') = 'admin'
                                 or a.user_id = s.user_id
                                 or app_private._unit_in_scope(a.unit_id::text, s.unit_id, s.u_path) as v) ok
     order by u.path nulls first, a.user_id;
end $$;
grant execute on function public.list_accounts() to anon, authenticated;

-- 2) settings_merge — cần phiên
create or replace function public.settings_merge(p_key text, p_set jsonb, p_del text[])
returns void
language plpgsql security definer
set search_path = public
as $$
declare s public.app_sessions;
begin
  s := app_private._app_sess();
  if s.token is null then raise exception 'ERR_SESSION: cần đăng nhập để ghi cài đặt'; end if;
  insert into public.settings(key, value) values (p_key, coalesce(p_set, '{}'::jsonb))
  on conflict (key) do update
    set value = (coalesce(public.settings.value, '{}'::jsonb) - coalesce(p_del, '{}'::text[]))
                || coalesce(p_set, '{}'::jsonb);
end $$;
grant execute on function public.settings_merge(text, jsonb, text[]) to anon, authenticated;

-- 3) Bỏ chỉ mục UNIQUE trùng (giữ uq_reports_row — cùng cột, cùng thứ tự)
do $$
begin
  if to_regclass('public.uq_reports_row') is not null
     and to_regclass('public.ux_reports_key') is not null
     and not exists (select 1 from pg_constraint where conindid = 'public.ux_reports_key'::regclass) then
    execute 'drop index public.ux_reports_key';
  end if;
end $$;

-- 4) search_path cố định
alter function app_private._period_of(date, text) set search_path = public;
alter function public.trg_reports_edit_lock() set search_path = public;

notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════
-- KIỂM TRA (chỉ ĐỌC): gọi khi chưa đăng nhập phải báo ERR_SESSION
--   select * from public.list_accounts();
-- ═══════════════════════════════════════════════════════════════════════
