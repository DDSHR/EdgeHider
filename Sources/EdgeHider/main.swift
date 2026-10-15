import AppKit
import SwiftUI

// MARK: - App 代理
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    private var terminationPollTimer: Timer?
    private var terminationDeadline: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不在 Dock 显示图标
        NSApp.setActivationPolicy(.accessory)

        // 加载已保存的全局设置
        AppListManager.shared.loadGlobalSettings()

        // 启动核心服务
        EdgeHiderService.shared.start()

        // 创建菜单栏图标
        setupStatusItem()

        // 首次启动：如果没有权限，主动弹设置窗口引导授权
        if !AnimationEngine.isTrusted {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EdgeHiderService.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if EdgeHiderService.shared.prepareForTermination() { return .terminateNow }
        guard terminationPollTimer == nil else { return .terminateLater }
        terminationDeadline = ProcessInfo.processInfo.systemUptime + 3
        terminationPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if EdgeHiderService.shared.prepareForTermination()
                || ProcessInfo.processInfo.systemUptime >= self.terminationDeadline {
                timer.invalidate()
                self.terminationPollTimer = nil
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    // MARK: - 菜单栏
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "EdgeHider")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        // 主开关
        let masterItem = NSMenuItem(title: "启用 EdgeHider", action: #selector(toggleMaster(_:)), keyEquivalent: "")
        masterItem.state = AppListManager.shared.globalSettings.isMasterEnabled ? .on : .off
        masterItem.target = self
        menu.addItem(masterItem)
        menu.addItem(NSMenuItem.separator())

        // 自动隐藏延迟子菜单
        let delayItem = NSMenuItem(title: "自动隐藏延迟", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        let delays: [(String, TimeInterval)] = [("立即", 0), ("0.5 秒", 0.5), ("1 秒", 1.0), ("1.5 秒", 1.5), ("2 秒", 2.0), ("3 秒", 3.0)]
        for (title, val) in delays {
            let item = NSMenuItem(title: title, action: #selector(setDelay(_:)), keyEquivalent: "")
            item.tag = Int(val * 10)
            item.target = self
            if abs(AppListManager.shared.globalSettings.autoHideDelay - val) < 0.01 {
                item.state = .on
            }
            delayMenu.addItem(item)
        }
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        // 露出边条子菜单
        let peekItem = NSMenuItem(title: "露出边条宽度", action: nil, keyEquivalent: "")
        let peekMenu = NSMenu()
        let peeks: [(String, CGFloat)] = [("完全隐藏 (0px)", 0), ("5px", 5), ("10px", 10), ("15px", 15), ("20px", 20), ("30px", 30)]
        for (title, val) in peeks {
            let item = NSMenuItem(title: title, action: #selector(setPeek(_:)), keyEquivalent: "")
            item.tag = Int(val)
            item.target = self
            if abs(AppListManager.shared.globalSettings.peekStripWidth - val) < 0.1 {
                item.state = .on
            }
            peekMenu.addItem(item)
        }
        peekItem.submenu = peekMenu
        menu.addItem(peekItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "打开设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "重新扫描窗口", action: #selector(rescan), keyEquivalent: "")
        menu.addItem(withTitle: "关于 EdgeHider", action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 EdgeHider", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items {
            if item.target == nil { item.target = self }
        }

        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = AppListManager.shared.globalSettings
        for item in menu.items {
            if item.action == #selector(toggleMaster(_:)) { item.state = settings.isMasterEnabled ? .on : .off }
            for child in item.submenu?.items ?? [] {
                if child.action == #selector(setDelay(_:)) {
                    child.state = abs(Double(child.tag) / 10 - settings.autoHideDelay) < 0.01 ? .on : .off
                } else if child.action == #selector(setPeek(_:)) {
                    child.state = abs(CGFloat(child.tag) - settings.peekStripWidth) < 0.1 ? .on : .off
                }
            }
        }
    }

    @objc func toggleMaster(_ sender: NSMenuItem) {
        AppListManager.shared.globalSettings.isMasterEnabled.toggle()
        sender.state = AppListManager.shared.globalSettings.isMasterEnabled ? .on : .off
    }

    @objc func setDelay(_ sender: NSMenuItem) {
        let val = TimeInterval(sender.tag) / 10.0
        AppListManager.shared.globalSettings.autoHideDelay = val
        // 刷新菜单勾选
        for item in (sender.menu?.items ?? []) {
            item.state = (Int(AppListManager.shared.globalSettings.autoHideDelay * 10) == item.tag) ? .on : .off
        }
    }

    @objc func setPeek(_ sender: NSMenuItem) {
        AppListManager.shared.globalSettings.peekStripWidth = CGFloat(sender.tag)
        for item in (sender.menu?.items ?? []) {
            item.state = (Int(AppListManager.shared.globalSettings.peekStripWidth) == item.tag) ? .on : .off
        }
    }

    private var aboutWC: AboutWindowController?
    @objc func openAbout() {
        if aboutWC == nil {
            aboutWC = AboutWindowController()
        }
        aboutWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "EdgeHider 设置"
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable]
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func rescan() {
        // 重启服务以立即刷新
        EdgeHiderService.shared.stop()
        EdgeHiderService.shared.start()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - 关于窗口
class AboutWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "关于 EdgeHider"
        window.isReleasedWhenClosed = false
        window.center()

        let title = NSTextField(labelWithString: "EdgeHider")
        title.font = NSFont.boldSystemFont(ofSize: 20)
        title.alignment = .center
        title.frame = NSRect(x: 20, y: 150, width: 320, height: 30)

        let version = NSTextField(labelWithString: "版本 1.1.4")
        version.font = NSFont.systemFont(ofSize: 12)
        version.alignment = .center
        version.frame = NSRect(x: 20, y: 125, width: 320, height: 20)

        let author = NSTextField(labelWithString: "作者：Doon")
        author.font = NSFont.systemFont(ofSize: 12)
        author.alignment = .center
        author.frame = NSRect(x: 20, y: 95, width: 320, height: 20)

        let desc = NSTextField(labelWithString: "把窗口拖到屏幕边缘自动隐藏，鼠标悬停标签弹出")
        desc.font = NSFont.systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 20, y: 58, width: 320, height: 20)

        window.contentView?.addSubview(title)
        window.contentView?.addSubview(version)
        window.contentView?.addSubview(author)
        window.contentView?.addSubview(desc)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
