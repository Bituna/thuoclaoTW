-- ═══════════════════════════════════════════════════════════════════════
-- 05_du_lieu_tham_chieu.sql — thuoclaoTW
-- Chạy 1 lần trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn:
-- KHÔNG ghi đè nếu đã có — chỉnh sửa của bạn trên Supabase được giữ nguyên).
--
-- Đưa PHÁC ĐỒ ĐIỀU TRỊ lên Supabase (bảng settings, key = 'PHAC_DO').
-- App đọc phác đồ từ đây khi khởi động; bảng trong code chỉ còn là dự phòng.
--
-- Định dạng: { "<tên phác đồ>": [ {"drug": "<tên thuốc đúng như danh mục>", "daily": <số viên/ngày>}, ... ], ... }
--  • "Khác": [] — bắt buộc giữ (nhập phác đồ tự do, hệ thống tự quét tên thuốc).
--  • Bedaquiline luôn tính theo thuật toán riêng (nạp 2 tuần → duy trì), "daily" chỉ để dự phòng.
--  • Liều theo cân nặng (WHO 2022) vẫn tính trong code; "daily" dùng khi thuốc không có trong bảng WHO.
--
-- Sửa phác đồ sau này: Supabase → Table Editor → settings → dòng key = PHAC_DO → sửa cột value,
-- rồi tải lại trang. Sai định dạng → app giữ bảng dự phòng và ghi cảnh báo trong Console.
-- Ngưỡng cảnh báo đã lưu sẵn ở settings key = 'threshold' (sửa ở trang Cài đặt).
-- ═══════════════════════════════════════════════════════════════════════

insert into public.settings (key, value)
values ('PHAC_DO', '{
  "6BPaLM": [
    {
      "drug": "Bedaquiline 100mg",
      "daily": 1
    },
    {
      "drug": "Pretomanid 200mg",
      "daily": 1
    },
    {
      "drug": "Linezolid 600mg",
      "daily": 1
    },
    {
      "drug": "Moxifloxacin 400mg",
      "daily": 1
    }
  ],
  "18-20BdqLfxLzdCfzCs": [
    {
      "drug": "Bedaquiline 100mg",
      "daily": 1
    },
    {
      "drug": "Levofloxacin 250mg",
      "daily": 4
    },
    {
      "drug": "Linezolid 600mg",
      "daily": 1
    },
    {
      "drug": "Clofazimine 100mg",
      "daily": 1
    },
    {
      "drug": "Cycloserine 250mg",
      "daily": 2
    }
  ],
  "18-20LfxLzdCfzCsE": [
    {
      "drug": "Levofloxacin 250mg",
      "daily": 4
    },
    {
      "drug": "Linezolid 600mg",
      "daily": 1
    },
    {
      "drug": "Clofazimine 100mg",
      "daily": 1
    },
    {
      "drug": "Cycloserine 250mg",
      "daily": 2
    },
    {
      "drug": "Ethambutol 400mg",
      "daily": 3
    }
  ],
  "18-20LfxZCfzCsE": [
    {
      "drug": "Levofloxacin 250mg",
      "daily": 4
    },
    {
      "drug": "Linezolid 300mg",
      "daily": 2
    },
    {
      "drug": "Clofazimine 100mg",
      "daily": 1
    },
    {
      "drug": "Cycloserine 250mg",
      "daily": 2
    },
    {
      "drug": "Ethambutol 400mg",
      "daily": 3
    }
  ],
  "Khác": []
}')
on conflict (key) do nothing;

-- Kiểm tra
select key, value from public.settings where key = 'PHAC_DO';
