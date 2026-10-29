# thuoclaoTW

## Cài đặt SQL (Supabase → SQL Editor)

Chạy lần lượt, mỗi file 1 lần (chạy lại vẫn an toàn):

1. `01_schema_da_tinh.sql` — bảng, tài khoản, đăng nhập (chưa có trong repo)
2. `sql/02_bao_mat_ghi_va_cascade.sql` — phiên đăng nhập, chặn ghi khi chưa đăng nhập, lan tồn đầu kỳ
3. `sql/03_quan_ly_mien.sql` — quản lý miền
4. `sql/04_siet_quyen_ghi.sql` — siết quyền ghi theo phạm vi đơn vị, gỡ mật khẩu cũ khỏi `settings`
5. `sql/05_cot_thua_n4.sql` — thêm cột **Thừa** (`n4`) vào `reports`; lan tồn đầu kỳ và khoá sửa tính cả Thừa
