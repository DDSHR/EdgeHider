import AppKit
import ApplicationServices
import Combine

final class EdgeHiderService {
    static let shared = EdgeHiderService()
    private var scanTimer: Timer?
    private var mouseTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    enum WinState { case normal, hiding, hidden, showing }

    final class ManagedWin {
        let axWin: AXUIElement
        let pid: pid_t
        let bundleID: String
        var originalFrame: CGRect
        var screenFrame: CGRect
        var state: WinState = .normal
        var side: HiddenSide = .left
        var barPanel: EdgeBarPanel?
        var autoHideAt: TimeInterval?
        var attached = false
        var hiddenFrame: CGRect?
        var cooldown: TimeInterval = 0

        init(axWin: AXUIElement, frame: CGRect, screen: CGRect, pid: pid_t, bundleID: String) {
            self.axWin = axWin
            self.originalFrame = frame
            self.screenFrame = screen
            self.pid = pid
            self.bundleID = bundleID
        }
    }

    private var managed: [String: ManagedWin] = [:]
    private var previousPeek: CGFloat?
    private init() {}

    func start() {
        guard scanTimer == nil else { return }
        let manager = AppListManager.shared
        manager.$globalSettings.map { _ in () }
            .merge(with: manager.$appConfigs.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reconcileSettings() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restoreAll() }
            .store(in: &subscriptions)
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.scanEnabledApps() }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.handleMouse() }
    }

    func stop() {
        scanTimer?.invalidate(); scanTimer = nil
        mouseTimer?.invalidate(); mouseTimer = nil
        subscriptions.removeAll()
        restoreAll()
    }

    private func restoreAll() {
        for key in Array(managed.keys) { remove(key, restore: true) }
    }

    private func remove(_ key: String, restore: Bool) {
        guard let mw = managed.removeValue(forKey: key) else { return }
        AnimationEngine.shared.stopAnimation(key: key)
        mw.barPanel?.onHover = nil
        mw.barPanel?.close(); mw.barPanel = nil
        if restore && mw.state != .normal,
           let screen = WindowGeometry.screen(for: mw.originalFrame, screens: NSScreen.screens.map(\.visibleFrame)) {
            AnimationEngine.shared.setAXFrame(WindowGeometry.visible(mw.originalFrame, screen: screen),
                                             of: mw.axWin, screenFrame: screen)
        }
    }

    private func reconcileSettings() {
        let manager = AppListManager.shared
        guard manager.globalSettings.isMasterEnabled else { restoreAll(); return }
        let peek = manager.globalSettings.peekStripWidth
        let peekChanged = previousPeek != nil && previousPeek != peek
        previousPeek = peek
        for (key, mw) in Array(managed) {
            let config = manager.config(for: mw.bundleID)
            if !config.isEnabled || (mw.attached && config.hiddenSide != .automatic && config.hiddenSide != mw.side) {
                remove(key, restore: true)
            } else if peekChanged && mw.state != .normal {
                // 中途变更隐藏宽度，取消旧动画，使用新终点，避免过期回调覆盖设置。
                AnimationEngine.shared.stopAnimation(key: key)
                let target = WindowGeometry.hidden(mw.originalFrame, side: mw.side, screen: mw.screenFrame, peek: peek)
                AnimationEngine.shared.forceHidePosition(target, of: mw.axWin, screenFrame: mw.screenFrame)
                mw.hiddenFrame = AnimationEngine.frame(of: mw.axWin) ?? target
                mw.state = .hidden
                createBarPanel(key: key, mw: mw)
            }
        }
    }

    private func scanEnabledApps() {
        reconcileSettings()
        guard AppListManager.shared.globalSettings.isMasterEnabled, AnimationEngine.isTrusted else { return }
        let screens = NSScreen.screens.map(\.frame)
        guard !screens.isEmpty else { return }
        for bundleID in AppListManager.shared.enabledBundleIds {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let pid = app.processIdentifier
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.2)
                var value: AnyObject?
                // 暂时无响应不等于窗口已关闭，保留恢复入口。
                guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { continue }
                var seen = Set<String>()
                let config = AppListManager.shared.config(for: bundleID)
                for win in windows {
                    let key = "\(pid)-\(CFHash(win))"
                    seen.insert(key)
                    if let existing = managed[key], existing.state != .normal {
                        if existing.state == .hidden, let expected = existing.hiddenFrame,
                           let actual = AnimationEngine.frame(of: win),
                           abs(actual.minX - expected.minX) > 30 || abs(actual.minY - expected.minY) > 30 {
                            // 用户或目标应用主动移回窗口，撤销旧的隐藏状态。
                            existing.barPanel?.close(); existing.barPanel = nil
                            existing.originalFrame = actual
                            existing.state = .normal
                            existing.attached = false
                            existing.cooldown = ProcessInfo.processInfo.systemUptime + 2
                        } else { continue }
                    }
                    guard let frame = AnimationEngine.frame(of: win) else { continue }
                    guard WindowEligibility.allows(win, frame: frame) else {
                        remove(key, restore: false)
                        continue
                    }
                    guard let screen = WindowGeometry.screen(for: frame, screens: screens) else { continue }
                    let usable = NSScreen.screens.first { $0.frame == screen }?.visibleFrame ?? screen
                    let mw = managed[key] ?? ManagedWin(axWin: win, frame: frame, screen: screen, pid: pid, bundleID: bundleID)
                    managed[key] = mw
                    mw.screenFrame = screen
                    mw.originalFrame = frame
                    let side = WindowGeometry.edge(frame: frame, screen: usable,
                                                   threshold: config.edgeThreshold, preferred: config.hiddenSide)
                    guard let side else {
                        mw.attached = false; mw.autoHideAt = nil
                        continue
                    }
                    if NSEvent.pressedMouseButtons != 0 { mw.autoHideAt = nil; continue }
                    if !mw.attached && ProcessInfo.processInfo.systemUptime >= mw.cooldown {
                        hide(key: key, mw: mw, side: side)
                    }
                }
                for (key, mw) in Array(managed) where mw.pid == pid && !seen.contains(key) {
                    remove(key, restore: false)
                }
            }
        }
        for (key, mw) in Array(managed) where NSRunningApplication(processIdentifier: mw.pid) == nil {
            remove(key, restore: false)
        }
        rearrangeBars()
    }

    private func hide(key: String, mw: ManagedWin, side: HiddenSide) {
        guard mw.state == .normal else { return }
        // 扫描与鼠标定时器共用最后一道检查，防止旧窗口变成截屏/全屏界面后仍被隐藏。
        guard let from = AnimationEngine.frame(of: mw.axWin) else { return }
        guard WindowEligibility.allows(mw.axWin, frame: from) else {
            remove(key, restore: false)
            return
        }
        mw.side = side
        mw.attached = true
        mw.autoHideAt = nil
        let usable = NSScreen.screens.first { $0.frame == mw.screenFrame }?.visibleFrame ?? mw.screenFrame
        mw.originalFrame = WindowGeometry.aligned(from, side: side, screen: usable)
        let target = WindowGeometry.hidden(mw.originalFrame, side: side, screen: mw.screenFrame,
                                           peek: AppListManager.shared.globalSettings.peekStripWidth)
        mw.state = .hiding
        let config = AppListManager.shared.config(for: mw.bundleID)
        AnimationEngine.shared.animate(win: mw.axWin, key: key, from: from, to: target,
            type: config.animationType, side: side, screenFrame: mw.screenFrame, isHiding: true) { [weak self, weak mw] in
            guard let self, let mw, self.managed[key] === mw else { return }
            AnimationEngine.shared.forceHidePosition(target, of: mw.axWin, screenFrame: mw.screenFrame)
            mw.hiddenFrame = AnimationEngine.frame(of: mw.axWin) ?? target
            mw.state = .hidden
            self.createBarPanel(key: key, mw: mw)
        }
    }

    private func createBarPanel(key: String, mw: ManagedWin) {
        mw.barPanel?.close()
        guard let app = NSRunningApplication(processIdentifier: mw.pid) else { return }
        let panel = EdgeBarPanel(pid: mw.pid, icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
                                 screenFrame: mw.screenFrame, side: mw.side)
        panel.onHover = { [weak self] in self?.showWindow(key: key) }
        mw.barPanel = panel
        rearrangeBars()
        panel.orderFrontRegardless()
    }

    private func rearrangeBars() {
        for screen in NSScreen.screens {
            for side in HiddenSide.allCases where side != .automatic {
                let windows = managed.sorted { $0.key < $1.key }.map(\.value)
                    .filter { $0.state == .hidden && $0.screenFrame == screen.frame && $0.side == side }
                let horizontal = side == .top || side == .bottom
                let length = horizontal ? screen.frame.width : screen.frame.height
                let stride = min(CGFloat(64), length / CGFloat(max(1, windows.count)))
                let start = (horizontal ? screen.frame.midX : screen.frame.midY) - CGFloat(windows.count) * stride / 2
                for (index, mw) in windows.enumerated() {
                    mw.barPanel?.moveTo(offset: start + CGFloat(index) * stride, screenFrame: screen.frame, side: side)
                }
            }
        }
    }

    private func showWindow(key: String) {
        guard AppListManager.shared.globalSettings.isMasterEnabled,
              let mw = managed[key], mw.state == .hidden,
              AppListManager.shared.config(for: mw.bundleID).isEnabled else { return }
        mw.state = .showing
        mw.barPanel?.close(); mw.barPanel = nil
        let from = AnimationEngine.frame(of: mw.axWin) ?? mw.hiddenFrame ?? mw.originalFrame
        let config = AppListManager.shared.config(for: mw.bundleID)
        AnimationEngine.shared.animate(win: mw.axWin, key: key, from: from, to: mw.originalFrame,
            type: config.animationType, side: mw.side, screenFrame: mw.screenFrame, isHiding: false) { [weak self, weak mw] in
            guard let self, let mw, self.managed[key] === mw else { return }
            AnimationEngine.shared.setAXFrame(mw.originalFrame, of: mw.axWin, screenFrame: mw.screenFrame)
            mw.originalFrame = AnimationEngine.frame(of: mw.axWin) ?? mw.originalFrame
            mw.state = .normal
            mw.autoHideAt = nil
            mw.cooldown = ProcessInfo.processInfo.systemUptime + 0.5
            NSRunningApplication(processIdentifier: mw.pid)?.activate(options: [.activateIgnoringOtherApps])
            AXUIElementPerformAction(mw.axWin, kAXRaiseAction as CFString)
        }
    }

    private func handleMouse() {
        let settings = AppListManager.shared.globalSettings
        guard settings.isMasterEnabled, AnimationEngine.isTrusted else { return }
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        for (key, mw) in Array(managed) {
            guard AppListManager.shared.config(for: mw.bundleID).isEnabled else { continue }
            if mw.state == .hidden, let bar = mw.barPanel,
               mw.screenFrame.contains(mouse),
               WindowGeometry.hotZone(bar: bar.frame, side: mw.side, screen: mw.screenFrame,
                                      width: settings.hotZoneWidth).contains(mouse) {
                showWindow(key: key)
                continue
            }
            guard mw.state == .normal, mw.attached else { continue }
            guard NSEvent.pressedMouseButtons == 0, now >= mw.cooldown,
                  !AnimationEngine.boolAttribute(kAXMinimizedAttribute, of: mw.axWin),
                  !AnimationEngine.boolAttribute("AXFullScreen", of: mw.axWin),
                  let frame = AnimationEngine.frame(of: mw.axWin) else { mw.autoHideAt = nil; continue }
            guard WindowEligibility.allows(mw.axWin, frame: frame) else {
                remove(key, restore: false)
                continue
            }
            let config = AppListManager.shared.config(for: mw.bundleID)
            guard let screen = WindowGeometry.screen(for: frame, screens: NSScreen.screens.map(\.frame)),
                  screen == mw.screenFrame,
                  WindowGeometry.edge(frame: frame, screen: NSScreen.screens.first { $0.frame == screen }?.visibleFrame ?? screen, threshold: config.edgeThreshold, preferred: mw.side) != nil else {
                mw.attached = false; mw.autoHideAt = nil
                continue
            }
            mw.originalFrame = frame
            if frame.insetBy(dx: -5, dy: -5).contains(mouse) { mw.autoHideAt = nil; continue }
            if mw.autoHideAt == nil { mw.autoHideAt = now + settings.autoHideDelay }
            if let deadline = mw.autoHideAt, now >= deadline { hide(key: key, mw: mw, side: mw.side) }
        }
    }
}
