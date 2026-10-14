import Foundation
import AppKit
import Combine

/// 管理"哪些应用启用边缘隐藏"、每个应用的动画配置，以及持久化
final class AppListManager: ObservableObject {
    static let shared = AppListManager()

    /// 用户配置：bundleId -> AppConfig
    @Published private(set) var appConfigs: [String: AppConfig] = [:]

    /// 当前运行中的、可见的应用（排除后台服务）
    @Published private(set) var runningApps: [NSRunningApplication] = []

    private let defaults = UserDefaults.standard
    private let configKey = "EdgeHider.appConfigs.v1"
    private let globalKey = "EdgeHider.globalSettings.v1"

    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadConfigs()
        loadRunningApps()
        observeAppLifecycle()
    }

    // MARK: - 持久化
    private func loadConfigs() {
        if let data = defaults.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode([String: AppConfig].self, from: data) {
            appConfigs = decoded
        }
    }

    func saveConfigs() {
        if let data = try? JSONEncoder().encode(appConfigs) {
            defaults.set(data, forKey: configKey)
        }
    }

    // MARK: - 全局设置
    @Published var globalSettings: GlobalSettings = .default {
        didSet {
            if let data = try? JSONEncoder().encode(globalSettings) {
                defaults.set(data, forKey: globalKey)
            }
        }
    }

    func loadGlobalSettings() {
        if let data = defaults.data(forKey: globalKey),
           let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            globalSettings = decoded
        }
    }

    // MARK: - 运行中应用列表
    private func loadRunningApps() {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier, !id.isEmpty else { return false }
            guard app.activationPolicy != .prohibited else { return false }
            if id == Bundle.main.bundleIdentifier { return false }
            return true
        }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        runningApps = apps

        for app in apps {
            guard let id = app.bundleIdentifier else { continue }
            if appConfigs[id] == nil {
                var cfg = AppConfig.default
                cfg.bundleIdentifier = id
                cfg.appName = app.localizedName ?? id
                appConfigs[id] = cfg
            } else {
                appConfigs[id]?.appName = app.localizedName ?? id
            }
        }
        saveConfigs()
    }

    private func observeAppLifecycle() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadRunningApps()
            }
            .store(in: &cancellables)
    }

    // MARK: - 对外接口
    func config(for bundleId: String) -> AppConfig {
        if let config = appConfigs[bundleId] { return config }
        var config = AppConfig.default
        config.bundleIdentifier = bundleId
        return config
    }

    func updateConfig(_ config: AppConfig) {
        guard !config.bundleIdentifier.isEmpty else { return }
        appConfigs[config.bundleIdentifier] = config
        saveConfigs()
    }

    func toggleEnabled(bundleId: String) {
        guard var cfg = appConfigs[bundleId] else { return }
        cfg.isEnabled.toggle()
        appConfigs[bundleId] = cfg
        saveConfigs()
    }

    var enabledBundleIds: Set<String> {
        Set(appConfigs.values.filter { $0.isEnabled }.map { $0.bundleIdentifier })
    }

    func bundleId(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    // MARK: - 配置导出
    func exportConfig() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "EdgeHider配置-\(dateFormatter.string(from: Date())).json"
        panel.message = "选择保存 EdgeHider 配置的位置"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        var exportedSettings = globalSettings
        exportedSettings.launchAtLogin = LaunchAtLoginManager.isEnabled
        let file = ConfigFile(
            version: ConfigFile.currentVersion,
            exportedAt: Date(),
            globalSettings: exportedSettings,
            appConfigs: appConfigs
        )

        do {
            let data = try JSONEncoder.prettyEncoded.encode(file)
            try data.write(to: url)
            return url
        } catch {
            NSLog("导出失败: \(error)")
            return nil
        }
    }

    // MARK: - 配置导入
    func importConfig() throws -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择要导入的 EdgeHider 配置文件"

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder.imported.decode(ConfigFile.self, from: data)
            try file.validate()

            // 合并：导入的配置覆盖现有配置
            var newConfigs = appConfigs
            for (key, value) in file.appConfigs {
                newConfigs[key] = value
            }
            appConfigs = newConfigs
            saveConfigs()

            var imported = file.globalSettings
            imported.launchAtLogin = LaunchAtLoginManager.isEnabled
            globalSettings = imported
            return true
        } catch {
            throw error
        }
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }
}

// MARK: - JSONEncoder 扩展（美化输出）
extension JSONEncoder {
    static let prettyEncoded: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let imported: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
