import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var appList = AppListManager.shared
    @State private var hasAccessibility = AnimationEngine.isTrusted
    @State private var launchAtLogin = false
    @State private var importExportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !hasAccessibility { permissionBanner }
            Divider()
            globalSettingsSection
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已启用应用（勾选需要边缘隐藏的程序）")
                        .font(.headline)
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                    ForEach(appList.runningApps, id: \.processIdentifier) { app in
                        AppRowView(app: app)
                    }
                }
            }
        }
        .frame(width: 680, height: 620)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                hasAccessibility = AnimationEngine.isTrusted
                refreshLaunchAtLogin()
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sidebar.right").font(.title)
            VStack(alignment: .leading) {
                Text("EdgeHider").font(.title2.bold())
                Text("把窗口拖到屏幕边缘自动隐藏，鼠标靠近自动弹出")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("总开关", isOn: $appList.globalSettings.isMasterEnabled)
        }
        .padding(16)
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("需要辅助功能权限才能控制其他应用的窗口").font(.subheadline.bold())
                Text("请在弹出的系统设置中添加 EdgeHider，然后点击下方按钮刷新。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("去授权") { AnimationEngine.promptTrust() }
            Button("刷新状态") { hasAccessibility = AnimationEngine.isTrusted }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    private var globalSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("全局设置").font(.headline).padding(.horizontal, 16).padding(.top, 8)

            HStack {
                Text("鼠标热区宽度：")
                Slider(value: $appList.globalSettings.hotZoneWidth, in: 2...20)
                Text(String(format: "%.0f px", appList.globalSettings.hotZoneWidth)).frame(width: 50)
            }
            .padding(.horizontal, 16)

            HStack {
                Text("隐藏时露出边条：")
                Slider(value: $appList.globalSettings.peekStripWidth, in: 0...30)
                Text(String(format: "%.0f px", appList.globalSettings.peekStripWidth)).frame(width: 50)
            }
            .padding(.horizontal, 16)

            HStack(spacing: 16) {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { v in toggleLaunchAtLogin(v) }
                Spacer()
                Button("导出配置") {
                    if let url = appList.exportConfig() {
                        importExportMessage = "已导出到：\(url.lastPathComponent)"
                    }
                }
                Button("导入配置") {
                    do {
                        if try appList.importConfig() {
                            importExportMessage = "配置导入成功；开机启动保持本机设置"
                            refreshLaunchAtLogin()
                        } else { importExportMessage = "导入已取消" }
                    } catch { importExportMessage = "导入失败：\(error.localizedDescription)" }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let msg = importExportMessage {
                Text(msg).font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            }
        }
    }

    private func refreshLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = LaunchAtLoginManager.isEnabled
            appList.globalSettings.launchAtLogin = launchAtLogin
        }
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        guard on != LaunchAtLoginManager.isEnabled else { return }
        if let err = LaunchAtLoginManager.setEnabled(on) {
            importExportMessage = "开机自启失败：\(err)"
            launchAtLogin = LaunchAtLoginManager.isEnabled
        }
        appList.globalSettings.launchAtLogin = LaunchAtLoginManager.isEnabled
    }
}

struct AppRowView: View {
    let app: NSRunningApplication
    @ObservedObject private var appList = AppListManager.shared
    private var bundleId: String { app.bundleIdentifier ?? "" }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .application))
                .resizable().frame(width: 28, height: 28)

            Toggle(isOn: Binding(
                get: { appList.config(for: bundleId).isEnabled },
                set: { on in
                    var cfg = appList.config(for: bundleId)
                    cfg.isEnabled = on
                    appList.updateConfig(cfg)
                }
            )) {
                Text(app.localizedName ?? bundleId).frame(width: 130, alignment: .leading)
            }

            Picker("动画", selection: Binding(
                get: { appList.config(for: bundleId).animationType },
                set: { anim in
                    var cfg = appList.config(for: bundleId)
                    cfg.animationType = anim
                    appList.updateConfig(cfg)
                }
            )) {
                ForEach(AnimationType.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .frame(width: 150)

            Picker("方向", selection: Binding(
                get: { appList.config(for: bundleId).hiddenSide },
                set: { side in
                    var cfg = appList.config(for: bundleId)
                    cfg.hiddenSide = side
                    appList.updateConfig(cfg)
                }
            )) {
                ForEach(HiddenSide.allCases, id: \.self) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .frame(width: 100)

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
    }
}
