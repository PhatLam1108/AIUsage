# AIUsage: ghi chú phát triển

> Sổ tay kỹ thuật cho người muốn build, sửa hoặc đóng góp: kiến trúc, nguồn dữ liệu, cách build và phát hành, cùng các bẫy đã gặp. Giới thiệu ngắn gọn ở [README](../README.md); lịch sử thay đổi ở [CHANGELOG](../CHANGELOG.md).

## Kiến trúc

```
AIUsage.app (SwiftUI)            Widget (WidgetKit, sandbox)
      │  đọc                            │  đọc
      ▼                                 ▼
 ~/.ai_usage_cache.json  ◄── ghi ──  fetch_one.sh <nguồn>   (bash + Python)
                                        │
            ┌───────────────┬───────────┼──────────────┬─────────────────┐
            ▼               ▼           ▼              ▼                 ▼
   ClaudeUsageHelper   ~/.codex/    agy CLI      Google Cloud       SSH tới máy chủ
   (WKWebView:         auth.json    (expect)     (Monitoring,       (remote_insights.py
   claude.ai, Console, → chatgpt.com              Billing, BigQuery) gửi qua phiên SSH)
   AI Studio)
```

- App và widget **chỉ đọc** cache. Mọi lần lấy số liệu đi qua `fetch_one.sh <claude|codex|codexhist|agy|gemini|insights>`; script ghi phần của mình vào cache (ghi nguyên tử, có khoá file).
- Lúc mở lần đầu (và mỗi khi bản build đổi), `RuntimeInstaller` chép phần chạy nền đóng gói trong app sang `~/Library/Application Support/AIUsage/` và đăng ký 3 LaunchAgent. Người dùng không phải chạy script nào.
- Cấu hình nằm ở `~/Library/Application Support/AIUsage/config.json`, sửa qua cửa sổ Tài khoản: bật tắt từng nguồn, thông tin Gemini, danh sách máy chủ SSH. Khoá service account Google nằm trong Keychain, không nằm trong file.

### Cấu trúc mã nguồn

```
AIUsage/                 app
  AIUsageApp.swift       @main; chế độ --reload-widget; gọi RuntimeInstaller
  ContentView.swift      bảng điều khiển một màn hình + ScreenHugger (cửa sổ cao bằng màn hình)
  DashboardStore.swift   đọc cache, hành động (làm mới, đăng nhập, dùng lượt reset), mục "Cần chú ý"
  Components.swift       ô hạn mức, heat grid, các khối dùng chung, định dạng số và tiền
  AccountsView.swift     cửa sổ Tài khoản (một khung cho từng nguồn)
  Runtime.swift          đường dẫn, config, cài phần chạy nền, Shell, Keychain, lượt reset Codex
  Shared.swift           dùng chung với widget: màu, thanh usage, logo, dự báo theo nhịp
AIUsageWidget/           widget systemLarge, nút làm mới và đăng nhập (AppIntent)
ClaudeHelper/            mã nguồn helper WKWebView (được build trong lúc build app)
runtime/                 fetch_one.sh, fetch_usage.sh, login.sh, remote_insights.py
scripts/                 bundle-runtime.sh (build phase), build-dmg.sh (đóng gói bản phát hành)
```

## Nguồn dữ liệu

### Claude
- Helper mở `claude.ai/settings/usage` trong WKWebView (cookie lưu trong data store của helper) rồi trả về chữ trên trang, kèm JSON từ API usage của chính trang đó (`/api/organizations/<org>/usage`). JSON cho `five_hour`, `seven_day` và các hạn mức theo model (`weekly_scoped`, ví dụ Fable); phần chữ dùng làm dự phòng và để đọc mục "Limit resets".
- Không dùng Claude CLI hay OAuth API: CLI đổi tên binary theo phiên bản, còn OAuth token xoay vòng và dễ làm hỏng phiên của Claude Code.
- API credit (Anthropic Console) đọc từ trang dashboard của Console bằng chế độ `fetch-console` của helper, chạy song song.
- Hết phiên đăng nhập thì cache ghi `needs_login`, app và widget hiện nút đăng nhập lại. Cửa sổ đăng nhập tự đóng khi thấy trang đã đăng nhập.

### ChatGPT / Codex
- Token lấy từ `~/.codex/auth.json`, gọi `chatgpt.com/backend-api/wham/usage`. Cửa sổ 5 giờ và tuần được phân loại theo `limit_window_seconds`, không theo tên primary/secondary (OpenAI từng đổi định dạng).
- `codexhist` lấy lịch sử các khung giới hạn, dùng theo ngày và model, cùng lượt reset (`/wham/rate-limit-reset-credits`). Dùng lượt reset: `POST .../consume` với `credit_id`; app luôn hỏi xác nhận trước.
- Số lượt, token và context của Codex CLI đọc từ `~/.codex` (rollout JSONL và SQLite) bằng `remote_insights.py`, cùng một file cho máy này và máy chủ.

### Antigravity
- Chạy `agy` qua `expect`, gửi `/usage`, đọc 4 thanh. Chỉ dừng language server do chính lần chạy này tạo ra.

### Gemini API
- Số dư, lần nạp, tier: helper mở trang billing của AI Studio; khối số dư là iframe của payments.google.com, đọc bằng `evaluateJavaScript(in: frame)`.
- Token và request theo model: Cloud Monitoring, xác thực bằng service account (JWT ký bằng openssl). Lấy điểm thô rồi tự gộp theo ngày địa phương, vì bucket gộp sẵn của Google đếm dôi.
- Giá: Cloud Billing Catalog, có cache theo tiền tệ. Số ước tính cao hơn AI Studio khoảng 10% vì không có metric token cache.
- Số chính xác: BigQuery billing export khi bảng có dữ liệu. Export trễ vài ngày, nên tổng hôm nay, 7 ngày, tháng là lai: ngày đã có trong export lấy số chính xác, ngày sau đó lấy ước tính.

### Phân tích Claude Code
- Đọc `~/.claude/projects/**.jsonl` (CLI, VS Code), nhật ký Cowork trong Application Support của Claude, và các máy chủ SSH khai trong cửa sổ Tài khoản.
- Máy chủ: `remote_insights.py` được gửi qua chính phiên SSH (`ssh host 'python3 -' < remote_insights.py`), nên máy chủ chỉ cần python3, không phải cài gì. Script đọc tăng dần theo byte offset (state nằm trên máy chủ), trả JSON nén. Bản thành công gần nhất được giữ lại để mất kết nối vẫn còn số cũ.
- Trọng số một request gần với giá API: input 1, ghi cache 1,25, đọc cache 0,1, output 5.

## Giao diện

- Một màn hình, không có tab: dải "Cần chú ý" trên cùng, rồi ba cột liền theo hãng (Claude, OpenAI, Google), mỗi cột đọc từ trên xuống: hạn mức, tiền và lượt reset, phân tích, heat map.
- Cửa sổ cao bằng vùng nhìn thấy của màn hình (`ScreenHugger`), người dùng chọn chiều rộng. Màn hình thấp hơn mức tối thiểu thì cả bố cục được thu nhỏ đều thay vì cuộn. Khi kéo mép cửa sổ, bố cục được đóng băng và chỉ thu phóng hình, xong mới dựng lại một lần.
- Ô hạn mức: % đã dùng, thanh có vạch nhịp đều (chỗ lẽ ra đang ở nếu dùng đều cả chu kỳ), so với nhịp đều, và mức dùng tối đa để không chạm trần trước giờ reset. Logic dự báo ở `Shared.swift` (`paceFraction`, `projectedRunOut`, `paceStatus`) và `Components.swift` (`quotaRead`).
- "Cần chú ý" (`DashboardStore.attention`) chỉ dựng từ số liệu đã có: hạn mức sắp chạm trần hoặc dự kiến hết trước giờ reset, lượt reset còn lại, cần đăng nhập lại, số liệu cũ, số dư Gemini còn ít ngày, chi bất thường, máy chủ không kết nối được.
- Màu hãng chỉ để nhận diện; cam và đỏ chỉ dùng cho số và chữ trạng thái.

## Song ngữ

- Ngôn ngữ gốc là tiếng Việt (`developmentRegion = vi`), bản dịch tiếng Anh nằm trong String Catalog: `AIUsage/Localizable.xcstrings` cho app, `AIUsageWidget/Localizable.xcstrings` cho widget. App theo ngôn ngữ của macOS.
- Chuỗi trong `Text("...")`, `Button("...")`, `Label` được trích tự động. Chuỗi dựng trong code (thông báo, help, NSAlert) phải bọc `String(localized:)`. Câu có số dùng biến thể số nhiều trong catalog để tiếng Anh ra đúng "1 reset" và "2 resets".
- Hai chuỗi trùng chữ nhưng khác nghĩa thì dùng khoá riêng kèm `defaultValue`, ví dụ `calendar.sun` (CN trên lịch) khác "CN" trong câu dự báo.
- Helper (`ClaudeHelper.swift`) build bằng `swiftc`, không có catalog, nên dùng hàm `L(vi, en)` theo `Locale.preferredLanguages`.
- Thêm chuỗi mới: build một lần, rồi đồng bộ catalog từ các file `.stringsdata` của bản build (file catalog phải tên đúng `Localizable.xcstrings`):

```bash
xcrun xcstringstool sync AIUsage/Localizable.xcstrings \
  --stringsdata $(find build -path '*AIUsage.build*' -name '*.stringsdata')
```

  Build tăng dần có thể bỏ sót file, nên đồng bộ sau một bản build sạch. Chuỗi mới vào catalog ở trạng thái chưa dịch; điền bản tiếng Anh trong Xcode.
- Thử giao diện tiếng Anh mà không đổi ngôn ngữ máy: `open -n AIUsage.app --args -AppleLanguages '(en)'`. Ghim một ngôn ngữ cho riêng app: `defaults write com.stevenlam.AIUsage AppleLanguages -array vi`.

## Build và cài thử

Yêu cầu: macOS 26, Xcode 26, python3.

```bash
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release \
  -derivedDataPath build CURRENT_PROJECT_VERSION=$(date +%s) build
```

- Build phase "Bundle runtime" (`scripts/bundle-runtime.sh`) chép `runtime/` vào app và build helper cho từng kiến trúc trong `ARCHS`, ký bằng cùng chứng chỉ với app.
- Đặt `DEVELOPMENT_TEAM` của bạn trong Xcode trước khi build.
- Luôn kiểm tra dòng `BUILD SUCCEEDED` trước khi chép app đi đâu; lọc log bằng `grep` dễ che mất lỗi biên dịch.

Cài thử bản vừa build:

```bash
osascript -e 'tell application "AIUsage" to quit'
rm -rf /Applications/AIUsage.app
cp -R build/Build/Products/Release/AIUsage.app /Applications/
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
$LSR -u build/Build/Products/Release/AIUsage.app
$LSR -f -R /Applications/AIUsage.app
pkill -f AIUsageWidgetExtension
```

## Phát hành

```bash
scripts/build-dmg.sh          # build Release (arm64 + x86_64), tạo dist/AIUsage-<phiên bản>.dmg
```

- Bản phát hành được ký bằng chứng chỉ Apple Development, chưa notarize. README hướng dẫn mở lần đầu qua System Settings > Privacy & Security > Open Anyway.
- Mỗi bản: tăng `MARKETING_VERSION`, cập nhật `CHANGELOG.md` và `CHANGELOG.en.md`, phần "Có gì mới" trong README, rồi tạo GitHub Release đính kèm file DMG.
- Trang dự án và tài liệu trên phatdev.net được cập nhật cùng lúc với mỗi bản phát hành.

## Ảnh chụp công khai

Ảnh đưa lên README hoặc trang web chỉ dùng số liệu giả:

```bash
open -n /đường/dẫn/AIUsage-copy.app --env AIUSAGE_HOME=/thư/mục/mẫu --env AIUSAGE_APPEARANCE=dark
screencapture -o -x -l <windowID> shot.png
```

- `AIUSAGE_HOME` trỏ tới thư mục chứa `.ai_usage_cache.json` mẫu; ở chế độ này app không cài LaunchAgent và không chạy script lấy số, nên không ghi đè gì.
- Chạy thẳng tệp thực thi thì không có cửa sổ; phải mở bằng `open -n`.
- Quét lại ảnh và cache mẫu để chắc không còn tên máy, địa chỉ, ID project hay tên thư mục thật.

## Widget và các bẫy của chronod

- Widget đọc cache bằng đường dẫn tuyệt đối lấy từ `getpwuid` (sandbox đổi `NSHomeDirectory()` sang container).
- Nút làm mới của widget chỉ ghi file trigger rồi trả về ngay. LaunchAgent trigger chạy fetch, sau đó gọi `AIUsage --reload-widget` để nạp lại widget từ tiến trình app (đáng tin hơn gọi từ extension đang bị sandbox). Intent sống lâu làm widget chớp liên tục.
- WidgetKit chỉ cho khoảng 40 đến 70 lần nạp lại mỗi ngày. LaunchAgent 5 phút chạy với cờ `--scheduled` để không ép nạp lại; widget tự đọc cache theo timeline. Rebuild liên tục khi phát triển có thể làm cạn hạn mức, khi đó `killall chronod`.
- Tiến trình extension cũ sống qua nhiều lần cài: sau mỗi lần cài bản có sửa widget, chạy `pkill -f AIUsageWidgetExtension`.
- xcodebuild tự đăng ký app trong thư mục build; nếu không gỡ (`lsregister -u`), chronod có thể chạy extension từ đó.
- Widget gần như không còn chỗ theo chiều cao. Trước khi thêm dòng nào, dựng widget offline bằng `ImageRenderer` ở khung 344x345pt và đo chiều cao `fixedSize` để chắc không tràn.

## Các bẫy khác

- **WKWebView ẩn không render:** cửa sổ nằm ngoài màn hình hoặc alpha 0 làm trang ở trạng thái hidden, `innerText` rỗng. Helper đặt cửa sổ trên màn hình với alpha 0,01 và bỏ qua chuột.
- **Ký tự icon trong Console:** chữ trang có ký tự private-use (U+E000 đến U+F8FF) giữa nhãn và số; parser lọc chúng trước.
- **codesign trong Documents:** báo "resource fork, Finder information, or similar detritus". Chép bằng `ditto --norsrc --noextattr` (hoặc `cp -X`) sang thư mục tạm rồi ký.
- **Tách trường bằng tab trong bash:** `read` gộp các tab liền nhau, trường trống làm lệch cột. Script dùng ký tự `\x1f` làm dấu phân cách.
- **Material trong suốt:** nền mờ thành xám đục khi phía sau là cửa sổ sáng; app và widget dùng nền đặc.
- **Title bar:** dùng toolbar gốc của macOS, không tự vẽ header đè lên hàng nút cửa sổ.
