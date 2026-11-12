// CastPopover.swift: toolbar button + popover to show the dashboard on a Cast display.

import SwiftUI

struct CastToolbarButton: View {
    @State private var open = false
    private var cast: CastController { CastController.shared }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: cast.showing ? "tv.fill" : "tv")
                .foregroundStyle(cast.showing ? Color.accentColor : Color.primary)
        }
        .help("Hiển thị trên màn hình Cast (Nest Hub)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            CastPopover()
        }
    }
}

struct CastPopover: View {
    private var cast: CastController { CastController.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Hiển thị trên màn hình Cast").font(.headline)
                Text("Bảng số liệu gọn cho Nest Hub và màn hình Google Cast trong cùng mạng. Số liệu đi thẳng từ máy Mac tới màn hình.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 2) {
                if cast.devices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Đang tìm màn hình trong mạng…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                ForEach(cast.devices) { d in
                    deviceRow(d)
                }
            }

            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if cast.enabled {
                    Button("Dừng hiển thị") { cast.stop() }
                        .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear { cast.startBrowsing() }
        .onDisappear { cast.stopBrowsingIfIdle() }
    }

    private func deviceRow(_ d: CastDevice) -> some View {
        let active = cast.enabled && cast.deviceID == d.id
        return Button {
            if !active { cast.cast(to: d) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: active && cast.showing ? "tv.fill" : "tv")
                    .font(.system(size: 15))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(.body.weight(.medium))
                    if !d.model.isEmpty { Text(d.model).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.accentColor.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch cast.status {
        case .showing: return .green
        case .connecting, .launching, .searching: return .orange
        case .failed: return .red
        case .off: return .secondary.opacity(0.5)
        }
    }

    private var statusText: String {
        if !cast.configured { return String(localized: "Chưa có App ID của receiver") }
        let name = cast.device?.name ?? ""
        switch cast.status {
        case .off: return String(localized: "Đang tắt. Chọn một màn hình để bắt đầu.")
        case .searching: return String(localized: "Đang tìm màn hình đã chọn…")
        case .connecting: return String(localized: "Đang kết nối tới \(name)…")
        case .launching: return String(localized: "Đang mở AIUsage trên \(name)…")
        case .showing: return String(localized: "Đang hiển thị trên \(name)")
        case .failed(let why): return why
        }
    }
}
