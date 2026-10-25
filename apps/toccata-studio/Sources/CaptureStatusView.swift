import AppKit
import SwiftUI

struct CaptureStatusView: View {
    @EnvironmentObject private var refresher: LiveRefresher
    var connectedText = "键盘记录已连接"

    var body: some View {
        Group {
            if refresher.captureEnabled {
                Label(connectedText, systemImage: "circle.fill")
                    .foregroundStyle(.green)
            } else if refresher.isConnected {
                if refresher.permissionRequired {
                    Button(action: openInputMonitoringSettings) {
                        Label("需要输入监控权限", systemImage: "exclamationmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                } else {
                    Label("采集服务准备中", systemImage: "circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("键盘记录未连接", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        if refresher.permissionRequired {
            return "打开输入监控设置，允许 Toccata 记录键盘"
        }
        if refresher.isConnected && !refresher.captureEnabled {
            return "采集尚未就绪，可查看日志：\(AppPaths.supportDirectory.appendingPathComponent("core.log").path)"
        }
        return "键盘活动保存在本机"
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }
}
