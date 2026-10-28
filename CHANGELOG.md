# Nhật ký thay đổi - AIUsage

Theo chuẩn [Keep a Changelog](https://keepachangelog.com/vi/1.1.0/) và [SemVer](https://semver.org/lang/vi/). Bản 0.9.0 là bản phát hành công khai đầu tiên (có file cài DMG); các phiên bản trước dùng cá nhân và được tổng hợp lại từ lịch sử commit theo từng mốc phát triển. Bản tiếng Anh: [CHANGELOG.en.md](CHANGELOG.en.md).

## [0.9.0] - 2026-10-28
Bản phát hành công khai đầu tiên: cài bằng file DMG trên mọi máy, giao diện song ngữ, cửa sổ Tài khoản cho từng nguồn, giao diện một màn hình làm lại hoàn toàn.

### Added - Cài đặt và cấu hình
- File cài `AIUsage-<phiên bản>.dmg` chạy trên cả Apple Silicon và Intel, đóng gói bằng `scripts/build-dmg.sh`. Script strip binary và từ chối đóng gói nếu bản build còn chứa đường dẫn của máy build.
- App tự cài phần chạy nền khi mở lần đầu và mỗi khi bản build đổi (`RuntimeInstaller`): script lấy số liệu, helper đăng nhập và 3 LaunchAgent vào `~/Library/Application Support/AIUsage`. Không còn bước chép script bằng tay.
- Cấu hình riêng từng máy ở `config.json` trong thư mục trên: bật tắt từng nguồn, thông tin Gemini, danh sách máy chủ SSH. Trước khi ghi luôn sao lưu `config.json.bak`; file không đọc được thì app không ghi đè.
- Cửa sổ **Tài khoản** (`Cmd+,`): một khung cho từng nguồn với trạng thái kết nối, nút đăng nhập (ẩn khi đã đăng nhập), công tắc bật tắt. Lần mở đầu tiên app tự mở cửa sổ này.
- Máy chủ SSH khai riêng từng máy: tên, địa chỉ, user, cổng, khoá; nút **Cài khoá SSH** mở Terminal để nhập mật khẩu máy chủ một lần; nút **Kiểm tra**.
- Khung Gemini API: nhập Project ID, billing account, bảng BigQuery và chọn file khoá service account (lưu vào Keychain), kèm hướng dẫn tạo khoá 8 bước. Hỗ trợ mọi loại tiền của tài khoản billing.

### Added - Bảng điều khiển
- Dải **Cần chú ý** trên cùng, dựng từ số liệu đã có: hạn mức sắp chạm trần hoặc dự kiến hết trước giờ reset, lượt reset còn lại, nguồn cần đăng nhập lại, số liệu cũ, số dư Gemini còn ít ngày, chi tiêu bất thường, máy chủ không kết nối được. Mỗi mục có nút xử lý.
- Ô hạn mức mới: % đã dùng, thời gian tới reset, so với nhịp đều (nhanh hay chậm bao nhiêu điểm) và mức còn dùng được mỗi giờ hoặc mỗi ngày để không chạm trần trước giờ reset.
- Nút dùng lượt reset của Codex (gọi API `rate-limit-reset-credits/consume`, luôn hỏi xác nhận, dùng lượt hết hạn sớm nhất trước) và danh sách từng lượt kèm hạn dùng. Claude: số lượt reset còn lại và nút mở trang reset của claude.ai. Hết lượt thì nút ẩn.
- Hạn mức tuần theo model của Claude (ví dụ Fable) trở lại, trong app và widget, đọc từ JSON của API usage mà trang claude.ai dùng.
- Biến môi trường `AIUSAGE_RANGE=week` để chụp ảnh ở chế độ 7 ngày.
- Giao diện song ngữ tiếng Việt và tiếng Anh cho app, widget và cửa sổ đăng nhập của helper (String Catalog, kèm dạng số ít và số nhiều cho tiếng Anh), tự theo ngôn ngữ của macOS.
- Giấy phép MIT (`LICENSE`) kèm bản dịch tiếng Việt (`LICENSE.vi.md`).

### Changed
- Giao diện làm lại hoàn toàn: một màn hình không có tab, ba cột liền theo hãng (Claude, OpenAI, Google), mỗi cột đọc từ trên xuống gồm hạn mức, tiền và lượt reset, phân tích, heat map. Thanh phẳng, bỏ hiệu ứng phát sáng và bóng nặng.
- Số liệu Claude lấy từ JSON của API usage (`five_hour`, `seven_day`, `weekly_scoped`) thay vì chỉ đọc chữ trên trang; phần chữ vẫn là dự phòng.
- Script chuyển vào `runtime/` và được đóng gói vào app khi build; helper được build trong build phase cho từng kiến trúc. Không còn hằng số ghi cứng (project Google Cloud, billing account, tên máy chủ, múi giờ cố định).
- Script phân tích máy chủ được gửi qua chính phiên SSH mỗi lần chạy, máy chủ chỉ cần `python3`.
- Widget thu gọn khoảng đệm để thêm dòng Fable mà vẫn vừa khung (đo offline: 336 trên 345 điểm).
- Tiền không phải VND hiển thị theo kiểu quốc tế (`$84.20`) bất kể vùng của hệ thống. Giờ hiển thị theo múi giờ của máy.

### Removed
- Thư mục `launchd/`, script ở thư mục gốc và bản helper build sẵn trong repo (thay bằng phần chạy nền đóng gói trong app).

### Fixed
- Máy chủ SSH có ô user trống bị đọc lệch cột (đường dẫn khoá thành số cổng, lỗi `Bad port`): `read` của bash gộp các tab liền nhau. Các trường nay tách bằng ký tự `\x1f`.
- Phân tích Claude Code dừng vì chia cho 0 khi một phiên không có request nào có trọng số.
- Đăng nhập Claude xong mà trạng thái vẫn báo chưa đăng nhập: cửa sổ đăng nhập nay tự đóng khi thấy trang đã đăng nhập và app lấy số ngay sau đó.

## [0.8.0] - 2026-10-23
Tín dụng API của Anthropic Console thay cho thanh Fable, và hoàn thiện cửa sổ đăng nhập của helper.

### Added
- Dòng `API $199.69` trong thẻ Claude (app và widget): số dư tín dụng API trên Anthropic Console. Gói Max tặng 200 USD tín dụng API mỗi tháng và cấp lại khi gia hạn. Thanh thể hiện phần trăm đã dùng, số dư nằm trong nhãn; không có vạch dự báo và đếm ngược vì Console không công bố ngày cấp lại.
- Helper đọc được `platform.claude.com/dashboard` qua hai chế độ mới `login-console` và `fetch-console`. `fetch_one.sh claude` đọc trang này song song với trang usage của claude.ai và lưu vào khoá `claude.api`: số dư, chi tiêu tháng, hạn mức tier và ngày reset, tỷ lệ prompt cache, token 7 ngày. Khi phiên đăng nhập hết hạn, số cũ được giữ lại và đặt `needs_login`.
- Cửa sổ đăng nhập của helper có icon ứng dụng và menu **Chỉnh sửa** (Hoàn tác, Làm lại, Cắt, Sao chép, Dán, Chọn tất cả), nên dán được mã xác nhận gửi qua email.
- Biến môi trường `AIUSAGE_HOME` (trỏ cache và script sang thư mục chứa số liệu mẫu) và `AIUSAGE_APPEARANCE` (`light` hoặc `dark`) để dựng ảnh giới thiệu mà không lộ số liệu thật.
- `CHANGELOG.en.md`, bản tiếng Anh của nhật ký thay đổi này.

### Changed
- Phiên bản ứng dụng (`MARKETING_VERSION`) đặt thành 0.8.0 cho khớp tài liệu.
- `README.md` và `README.en.md` có dòng phiên bản, hướng dẫn đăng nhập Console và liên kết tới hai bản nhật ký thay đổi.

### Removed
- Thanh Fable khỏi app và widget. Trang usage của claude.ai gập mục "This week", nên thanh này không đọc ổn định.

### Fixed
- Helper chạy nền đặt cửa sổ ngoài màn hình nên WebKit báo `visibilityState=hidden` và Anthropic Console (Next.js) không render, khiến `innerText` rỗng. Cửa sổ nay nằm trong màn hình ở độ trong suốt 99%, không nhận chuột.
- Ký ad-hoc cho helper lỗi `resource fork, Finder information, or similar detritus not allowed` khi bộ nguồn nằm trong Documents (File Provider gắn thuộc tính mở rộng). Quy trình build nay ký trên bản sao ở thư mục tạm.

## [0.7.0] - 2026-10-19
Tài liệu và dọn dẹp để đưa dự án lên GitHub.

### Added
- `README.md` (tiếng Việt, mặc định) và `README.en.md`, `CHANGELOG.md`, logo ở `docs/brand/`.
- Thư mục `launchd/` chứa ba LaunchAgent mẫu (dùng `__HOME__` thay cho đường dẫn người dùng) và script mở cửa sổ đăng nhập, để cài lại trên máy khác.
- Sổ tay kỹ thuật cũ chuyển sang `docs/DEVELOPMENT.md`.

### Removed
- `gen_project.py` (script sinh project, đã lỗi thời: file project do Xcode quản lý).
- File `__pycache__` bị commit nhầm; thêm `__pycache__/` và `*.pyc` vào `.gitignore`.

## [0.6.0] - 2026-10-06
### Added
- **Lượt reset giới hạn của Codex.** Codex tặng lượt reset (cả tuần lẫn 5 giờ, hết hạn sau 30 ngày). Card ChatGPT hiện "Còn N lượt reset · hết hạn …" cùng số lần đã dùng trong 30 ngày; card giới hạn Codex ghi số lần đã reset ở mục "Theo tuần".

## [0.5.0] - 2026-09-30
### Added
- **Dữ liệu Codex từ máy chủ** (nguồn mới `codexhist`), cùng API mà tab Analytics của app Codex dùng, bao gồm mọi thiết bị và nơi dùng:
  - Lịch sử giới hạn 5 giờ và tuần của 7 ngày qua, kèm tỷ lệ theo model và theo nguồn; đỏ khi chạm trần, tiêu đề ghi "chạm trần N/M lần".
  - Lưới "Codex theo ngày · model": bốn model dùng nhiều nhất trong 7 ngày.

### Changed
- Hai ô Codex tự đếm từ file (theo model và thư mục, theo giờ) được thay bằng hai ô dữ liệu máy chủ ở trên. Card "Codex CLI" vẫn giữ.

## [0.4.0] - 2026-09-29
Mở rộng nguồn dữ liệu và làm lại bố cục dashboard.

### Added
- **Phiên Cowork** được tính vào phần phân tích Claude (đọc nhật ký phiên của app Claude Desktop).
- **Máy chủ từ xa qua SSH.** Phiên Claude Code và Codex chạy trong VS Code Remote-SSH nằm trên máy chủ, không nằm trên Mac. `remote_insights.py` chạy trên máy đó, đọc tăng dần (lần đầu vài giây, sau đó dưới một giây) và trả JSON nén; mất kết nối thì dùng bản lần trước và footer ghi "(số cũ)".
- **Codex chi tiết:** thanh token chia input, cache, output và reasoning; kết quả lượt (xong, lỗi, ngắt); hoạt động (lệnh shell, sửa file, MCP, tìm web); theo model, nguồn và thư mục; biểu đồ theo giờ. Phân tích Codex dùng chung một file giữa Mac và máy từ xa để hai nơi không lệch logic.
- **Gemini theo model và dự báo:** phần trăm chi theo model, dự báo chi cuối tháng theo nhịp hiện tại, số ngày số dư còn đủ, trung bình mỗi ngày. Thêm lịch chi 30 ngày.
- **Biểu đồ dạng lưới ô đều** (giờ trong ngày, lịch chi Gemini) thay cho biểu đồ cột; ô đậm dần theo mức dùng, ô viền là thời điểm hiện tại.
- Cửa sổ tự bung **full chiều cao màn hình** (sát Dock, hoặc full màn khi không có Dock), kéo giãn tự do cả rộng lẫn cao và nhớ chiều rộng. Khi màn quá thấp, nội dung tự co đều thay vì bị cắt; không giật khi kéo.

### Changed
- Dashboard thành lưới 4 hàng × 3 cột bằng nhau (Claude, Codex, Gemini); ô cùng hàng cao bằng nhau.

### Fixed
- **Gemini:** BigQuery export chậm vài ngày làm "hôm nay" và "7 ngày" hiện 0. Giờ ngày chưa có số chính xác dùng ước tính từ Cloud Monitoring và nhãn ghi "đúng tới ngày …". Hoá đơn nạp tiền (không thuộc project nào) không còn bị cộng vào chi tháng.
- **Widget:** nút làm mới phải bấm hai lần mới cập nhật, do launchd giết tiến trình báo widget vẽ lại khi script thoát; chạy đồng bộ và thêm `AbandonProcessGroup`.
- Số trong ô giờ không còn bị cắt ("5…").

## [0.3.0] - 2026-09-27
Dashboard và Gemini API.

### Added
- **Gemini API (Google AI Studio):** số dư credit và lần nạp gần nhất đọc từ trang Billing qua helper (số dư nằm trong iframe của payments.google.com), chi phí và token theo model từ Cloud Monitoring, chi phí chính xác từ BigQuery billing export khi có, tiến độ tới tier kế tiếp.
- **Cửa sổ dashboard:** thanh quota, "Điều gì đang ăn quota Claude" (phiên chạy 8h+, context trên 150k, subagent), theo model và project, biểu đồ theo giờ, Codex, Gemini API. Chọn "Hôm nay" hoặc "7 ngày".
- **Codex đọc cả SQLite của bản 0.155:** đếm lượt thật (trước đây đếm mỗi phản hồi của model nên phóng đại hơn 20 lần) và nhận biết phiên đang mở nhưng chưa gửi lượt nào. Card phân biệt "chưa có lượt trong khoảng này" với "chưa thấy Codex".

### Changed
- Widget trả lề đúng 17pt mỗi cạnh, đo bằng ảnh dựng ngoài màn hình thay vì ước lượng; có lại đồng hồ giờ lấy dữ liệu; nút làm mới nằm cạnh giờ trên card Claude.
- Helper cho phép cửa sổ popup (`window.open`) để đăng nhập Google không bị treo.

## [0.2.0] - 2026-09-26
Làm lại giao diện và độ tin cậy.

### Added
- **Dự báo theo nhịp:** vạch dọc trên thanh quota và dòng trạng thái ("dư dả", "dự kiến hết …", "còn N%"); dùng logo thật của từng app thay cho logo vẽ lại.
- **Làm mới nền mỗi 5 phút.** Lần chạy theo lịch không ép widget vẽ lại để khỏi vượt ngân sách của WidgetKit; chỉ nút bấm mới ép.
- **Cảnh báo cũ theo từng nguồn:** mỗi nguồn có mốc lấy dữ liệu riêng, quá 90 phút thì card đó hiện cảnh báo (trước đây một cảnh báo chung bị che bởi nguồn còn chạy tốt).
- Đếm ngược chạy từng giây khi còn dưới 1 giờ; widget có mục "đang reset" khi quá giờ reset.

### Fixed
- Parser Claude theo nhãn mới của trang usage (`Your usage`, `Current session`, `This week`, `Fable this week`); nhãn Fable và phiên bản Gemini tự cập nhật theo hãng.
- Codex đổi định dạng API: các cửa sổ giờ được phân loại theo độ dài cửa sổ thay vì theo tên, kể cả đường dự phòng đọc từ file nhật ký.
- Lệnh `agy` không còn giết các phiên Antigravity của người dùng: chỉ tắt language server do chính lần fetch tạo ra.

## [0.1.0] - 2026-08-26
Bản đầu tiên.

### Added
- App macOS và widget cỡ lớn (SwiftUI, WidgetKit, Liquid Glass) hiển thị phần trăm đã dùng và thời gian reset của Claude, ChatGPT/Codex và Antigravity.
- Kiến trúc lấy dữ liệu: mỗi nguồn một lần fetch độc lập ghi vào một file cache chung (ghi nguyên tử, có khoá file); app và widget chỉ đọc cache.
- Claude đọc từ trang `claude.ai/settings/usage` bằng helper WKWebView có phiên đăng nhập; Codex qua API `wham/usage`; Antigravity qua `agy /usage`.
- Chế độ sáng/tối theo hệ thống; nút làm mới ở widget qua App Intent và LaunchAgent theo dõi file kích hoạt.
- Cờ `_fresh`: chỉ lần lấy thật sự thành công mới làm đồng hồ chung nhích; lỗi parser ghi vào `/tmp/ai_usage_err.log`.
