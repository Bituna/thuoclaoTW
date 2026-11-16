-- ═══════════════════════════════════════════════════════════════════════
-- 13_phan_phoi_nhap.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn). Yêu cầu: đã chạy 12.
--
-- Văn bản phân phối có 2 trạng thái:
--   'draft'  = NHÁP (đang làm dở): chỉ kho lập bảng thấy, sửa số tự do, chưa đưa vào đối chiếu.
--   'issued' = ĐÃ BAN HÀNH: đơn vị nhận thấy, số được đối chiếu; muốn sửa phải "Mở lại để sửa".
-- Văn bản đã có từ trước coi như ĐÃ BAN HÀNH (không ẩn dữ liệu đang dùng).
-- ═══════════════════════════════════════════════════════════════════════

alter table public.pp_docs add column if not exists status text not null default 'issued';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pp_docs_status_chk' and conrelid = 'public.pp_docs'::regclass) then
    alter table public.pp_docs add constraint pp_docs_status_chk check (status in ('draft', 'issued'));
  end if;
end $$;

-- Bảng đã BAN HÀNH: không sửa / xoá được dòng số liệu (phải mở lại thành nháp trước).
-- Đơn vị nhận không ghi nhận được theo văn bản còn NHÁP.
create or replace function public.trg_pp_status_guard()
returns trigger language plpgsql set search_path = public
as $$
declare v_doc uuid; v_st text;
begin
  if current_user not in ('anon', 'authenticated') then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;
  v_doc := case when TG_OP = 'DELETE' then OLD.doc_id else NEW.doc_id end;
  select d.status into v_st from public.pp_docs d where d.id = v_doc;
  if not found then return case when TG_OP = 'DELETE' then OLD else NEW end; end if;   -- xoá dây chuyền theo văn bản

  if TG_TABLE_NAME = 'pp_lines' and v_st = 'issued' then
    raise exception 'ERR_ISSUED: văn bản đã ban hành — bấm "Mở lại để sửa" trước khi đổi số';
  end if;
  if TG_TABLE_NAME = 'pp_receipts' and v_st = 'draft' and TG_OP <> 'DELETE' then
    raise exception 'ERR_DRAFT: văn bản còn là bản nháp — chưa ghi nhận được';
  end if;
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end $$;

drop trigger if exists trg_pp_status_guard on public.pp_lines;
create trigger trg_pp_status_guard before insert or update or delete on public.pp_lines
  for each row execute function public.trg_pp_status_guard();
drop trigger if exists trg_pp_status_guard on public.pp_receipts;
create trigger trg_pp_status_guard before insert or update or delete on public.pp_receipts
  for each row execute function public.trg_pp_status_guard();

notify pgrst, 'reload schema';

-- KIỂM TRA (chỉ ĐỌC):
--   select status, count(*) from public.pp_docs group by status;
