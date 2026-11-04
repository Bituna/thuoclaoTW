# thuoclaoTW

## Cài đặt SQL (Supabase → SQL Editor)

Chạy lần lượt, mỗi file 1 lần (chạy lại vẫn an toàn):

1. `01_schema_da_tinh.sql` — bảng, tài khoản, đăng nhập (chưa có trong repo)
2. `sql/02_bao_mat_ghi_va_cascade.sql` — phiên đăng nhập, chặn ghi khi chưa đăng nhập, lan tồn đầu kỳ
3. `sql/03_quan_ly_mien.sql` — quản lý miền
4. `sql/04_siet_quyen_ghi.sql` — siết quyền ghi theo phạm vi đơn vị, gỡ mật khẩu cũ khỏi `settings`
5. `sql/05_cot_thua_n4.sql` — thêm cột **Thừa** (`n4`) vào `reports`; lan tồn đầu kỳ và khoá sửa tính cả Thừa
6. `sql/06_dieu_chuyen_giao_dich.sql` — xác nhận / từ chối / huỷ phiếu điều chuyển chạy trọn 1 giao dịch trên máy chủ (app tự quay về cách cũ nếu chưa chạy)
7. `sql/07_siet_bao_mat_rpc.sql` — `list_accounts` / `settings_merge` bắt buộc đăng nhập (chặn lộ email, SĐT tài khoản và ghi cài đặt không đăng nhập); bỏ chỉ mục trùng
8. `sql/08_tai_khoan_an_toan.sql` — tài khoản: khoá là không đăng nhập được, admin không tự mất quyền, cấp dưới không đổi được cấp đơn vị, mật khẩu ≥ 8 ký tự, hàm tự sửa email/điện thoại
