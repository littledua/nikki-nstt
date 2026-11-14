# Bật thông báo góp ý mới về điện thoại

Làm 1 lần, khoảng 5 phút, trên máy tính cho dễ. Không cần tạo hay dán mã bí mật nào: máy chủ tự tạo khóa.

## Bước 1: Chạy SQL

1. Vào [Supabase](https://supabase.com/dashboard), mở dự án Nikki Diary (`yxlrhuzkgdigoacowsee`).
2. Bấm **SQL Editor** › **New query**.
3. Mở file [`03-thong-bao.sql`](03-thong-bao.sql), chép hết, dán vào, bấm **Run**. Thấy "Success" là xong.

## Bước 2: Tạo Edge Function

1. Bấm **Edge Functions** › **Deploy a new function** › **Via Editor**.
2. Đặt tên đúng: `quick-endpoint`.
3. Xóa code mẫu, dán toàn bộ file [`functions/quick-endpoint/index.ts`](functions/quick-endpoint/index.ts), bấm **Deploy**.
4. Vào function vừa tạo › **Details** (hoặc Settings), **tắt "Verify JWT"** (Enforce JWT Verification) rồi lưu. Hàm tự kiểm tra quyền nên tắt chỗ này là an toàn.

## Bước 3: Bật trên iPhone (iOS 16.4 trở lên)

1. Nếu đã có icon Nikki Diary ở màn hình chính từ trước, **xóa icon cũ** (giữ icon › Xóa bookmark).
2. Mở web bằng Safari › nút Chia sẻ › **Thêm vào MH chính**.
3. Mở web **từ icon mới**, vào **⚙ Quản trị** › **Cài đặt** › **Bật thông báo trên máy này** › chọn **Cho phép**.
4. Bấm **Gửi thử**. Thông báo hiện là xong.

Bấm vào thông báo góp ý mới sẽ mở thẳng Hộp thư.

## Nếu không thấy thông báo

- Cài đặt iPhone › Thông báo › Nikki Diary: bật **Cho phép thông báo**.
- Chế độ Tập trung / Không làm phiền có thể chặn.
- Supabase › Edge Functions › `quick-endpoint` › **Logs** xem có lỗi không.
