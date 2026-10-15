import AppKit
import ApplicationServices
import Combine
import os

final class EdgeHiderService {
    static let shared = EdgeHiderService()
    private var scanTimer: Timer?
    private var mouseTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private let session = SessionActivityMonitor()
    private var running = false
    private let sessionLog = Logger(subsystem: "com.edgehider.app", category: "SessionRecovery")
    enum WinState { case normal, hiding, hidden, showing }

    final class ManagedWin {
        var axWin: AXUIElement
        let pid: pid_t
        let bundleID: String
        /// 窗口交给 EdgeHider 隐藏前的位置；关闭总开关/退出时回到这里。
        var restoreFrame: CGRect
        /// 贴边后的可见位置，用来计算隐藏位置和标签位置。
        var originalFrame: CGRect
        var screenFrame: CGRect
        var state: WinState = .normal
        var side: HiddenSide = .left
        var barPanel: EdgeBarPanel?
        var autoHideAt: TimeInterval?
        var attached = false
        var hiddenFrame: CGRect?
        var cooldown: TimeInterval = 0
        var pendingRestore = false
        var needsSessionRecovery = false
        var waitForPointerExit = false

        init(axWin: AXUIElement, frame: CGRect, screen: CGRect, pid: pid_t, bundleID: String) {
            self.axWin = axWin
            self.restoreFrame = frame
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
        guard !running else { return }
        running = true
        session.onAvailabilityChanged = { [weak self] available in
            if available { self?.resumeSession() } else { self?.suspendSession() }
        }
        session.start()
        let manager = AppListManager.shared
        manager.$globalSettings.map { _ in () }
            .merge(with: manager.$appConfigs.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reconcileSettings() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            // 全屏 Space 切换可能伴随屏幕参数通知。清空 managed 会丢失隐藏窗口的 AX 恢复信息。
            .sink { [weak self] _ in self?.refreshPanelsForCurrentSpace() }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPanelsForCurrentSpace() }
            .store(in: &subscriptions)
        installTimers()
    }

    private func installTimers() {
        scanTimer?.invalidate()
        mouseTimer?.invalidate()
        let scan = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.scanEnabledApps() }
        let mouse = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.handleMouse() }
        RunLoop.main.add(scan, forMode: .common)
        RunLoop.main.add(mouse, forMode: .common)
        scanTimer = scan
        mouseTimer = mouse
    }

    private func suspendSession() {
        sessionLog.info("Suspending window operations; preserving \(self.managed.count) window records")
        for (key, mw) in managed {
            AnimationEngine.shared.stopAnimation(key: key)
            mw.needsSessionRecovery = true
            mw.autoHideAt = nil
            mw.barPanel?.onHover = nil
            mw.barPanel?.close(); mw.barPanel = nil
        }
    }

    private func resumeSession() {
        guard running else { return }
        sessionLog.info("Session available; rebuilding timers and recovering \(self.managed.count) windows")
        // 重新建立心跳；窗口恢复在后续成功的 AX 枚举中逐个完成，不抢占焦点。
        installTimers()
    }

    @discardableResult
    private func recoverSessionWindow(key: String, mw: ManagedWin) -> Bool {
        guard session.isAvailable, let frame = AnimationEngine.frame(of: mw.axWin) else { return false }
        if AnimationEngine.boolAttribute("AXFullScreen", of: mw.axWin) {
            remove(key, restore: false)
            return true
        }
        guard !AnimationEngine.boolAttribute(kAXMinimizedAttribute, of: mw.axWin) else { return false }
        let screens = NSScreen.screens
        let fallback = WindowGeometry.screen(for: mw.restoreFrame, screens: screens.map(\.frame))
        guard let screen = screens.first(where: { $0.frame == mw.screenFrame })
            ?? screens.first(where: { $0.frame == fallback }) else { return false }
        if mw.pendingRestore || !AppListManager.shared.globalSettings.isMasterEnabled
            || !AppListManager.shared.config(for: mw.bundleID).isEnabled {
            remove(key, restore: true)
            return managed[key] == nil
        }
        mw.screenFrame = screen.frame
        switch mw.state {
        case .hiding, .hidden:
            mw.originalFrame = WindowGeometry.aligned(mw.originalFrame, side: mw.side, screen: screen.visibleFrame)
            let target = WindowGeometry.hidden(mw.originalFrame, side: mw.side, screen: screen.frame,
                peek: AppListManager.shared.globalSettings.peekStripWidth)
            guard AnimationEngine.shared.setAXFrame(target, of: mw.axWin, screenFrame: screen.frame),
                  let actual = AnimationEngine.frame(of: mw.axWin),
                  WindowGeometry.matches(actual, target) else { return false }
            mw.hiddenFrame = actual
            mw.state = .hidden
        case .showing:
            guard restoreWindow(mw) else { return false }
            mw.state = .normal
            mw.originalFrame = mw.restoreFrame
        case .normal:
            mw.originalFrame = frame
        }
        mw.autoHideAt = nil
        mw.cooldown = ProcessInfo.processInfo.systemUptime + 1
        mw.needsSessionRecovery = false
        // 解锁时鼠标可能正停在旧热区，不应因此自动唤出并激活应用。
        mw.waitForPointerExit = mw.state == .hidden
        if mw.state == .hidden { createBarPanel(key: key, mw: mw) }
        return true
    }

    func stop() {
        // 先同步尝试恢复，再拆除监控；若暂时失败，记录仍保留以便服务重启后继续恢复。
        restoreAll()
        scanTimer?.invalidate(); scanTimer = nil
        mouseTimer?.invalidate(); mouseTimer = nil
        subscriptions.removeAll()
        running = false
        session.stop()
        session.onAvailabilityChanged = nil
    }

    /// 退出前先恢复所有窗口；返回 false 时由 AppDelegate 短暂等待并重试。
    func prepareForTermination() -> Bool {
        restoreAll()
        return managed.isEmpty
    }

    private func restoreAll() {
        for key in Array(managed.keys) { remove(key, restore: true) }
    }

    private func remove(_ key: String, restore: Bool) {
        guard let mw = managed[key] else { return }
        AnimationEngine.shared.stopAnimation(key: key)
        if restore && mw.state != .normal {
            // AX 请求在全屏切换期间可能暂时失败。保留记录并由扫描定时器重试，
            // 不能先删除恢复信息，否则窗口会永久留在屏幕外。
            mw.pendingRestore = true
            guard restoreWindow(mw) else { return }
        }
        managed.removeValue(forKey: key)
        mw.barPanel?.onHover = nil
        mw.barPanel?.close(); mw.barPanel = nil
    }

    private func restoreWindow(_ mw: ManagedWin) -> Bool {
        guard session.isAvailable else { return false }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        let targetScreen = WindowGeometry.screen(for: mw.restoreFrame, screens: screens.map(\.visibleFrame))
            ?? screens.first(where: { $0.frame == mw.screenFrame })?.visibleFrame
            ?? screens[0].visibleFrame
        let target = WindowGeometry.visible(mw.restoreFrame, screen: targetScreen)
        let current = AnimationEngine.frame(of: mw.axWin)
        if let current, WindowGeometry.matches(current, target) {
            return true
        }
        guard AnimationEngine.shared.setAXFrame(target, of: mw.axWin, screenFrame: targetScreen),
              let actual = AnimationEngine.frame(of: mw.axWin), WindowGeometry.matches(actual, target) else {
            return false
        }
        mw.restoreFrame = target
        return true
    }

    private func refreshPanelsForCurrentSpace() {
        guard running, session.isAvailable else { return }
        // 保留所有窗口的隐藏状态和恢复位置，只把恢复标签带到当前 Space。
        for mw in managed.values where mw.state == .hidden {
            mw.barPanel?.orderFrontRegardless()
        }
        rearrangeBars()
    }

    private func reconcileSettings() {
        guard session.isAvailable else { return }
        let manager = AppListManager.shared
        guard manager.globalSettings.isMasterEnabled else { restoreAll(); return }
        for (key, mw) in Array(managed) where mw.pendingRestore {
            remove(key, restore: true)
        }
        let peek = manager.globalSettings.peekStripWidth
        let peekChanged = previousPeek != nil && previousPeek != peek
        previousPeek = peek
        for (key, mw) in Array(managed) {
            let config = manager.config(for: mw.bundleID)
            if !config.isEnabled || (mw.attached && config.hiddenSide != .automatic && config.hiddenSide != mw.side) {
                remove(key, restore: true)
            } else if peekChanged && mw.state != .normal && !mw.needsSessionRecovery {
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
        guard running else { return }
        session.refresh()
        guard session.isAvailable else { return }
        reconcileSettings()
        guard AnimationEngine.isTrusted else { return }
        let screens = NSScreen.screens.map(\.frame)
        guard !screens.isEmpty else { return }
        // 即使解锁前关闭了总开关，也要刷新已有记录的 AX 句柄以完成恢复。
        let bundleIDs = AppListManager.shared.enabledBundleIds.union(managed.values.map(\.bundleID))
        for bundleID in bundleIDs {
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
                    AXUIElementSetMessagingTimeout(win, 0.2)
                    if let existing = managed[key] {
                        // 使用解锁后新枚举的句柄，避免一直调用锁屏前的失效 AX 对象。
                        existing.axWin = win
                        if existing.needsSessionRecovery {
                            recoverSessionWindow(key: key, mw: existing)
                            continue
                        }
                    }
                    if let existing = managed[key], existing.state != .normal {
                        if existing.state == .hidden, let expected = existing.hiddenFrame,
                           let actual = AnimationEngine.frame(of: win),
                           (abs(actual.minX - expected.minX) > 30 || abs(actual.minY - expected.minY) > 30),
                           isVisibleWindowFrame(actual),
                           WindowEligibility.allows(win, frame: actual) {
                            // 用户或目标应用主动移回窗口，撤销旧的隐藏状态。
                            existing.barPanel?.close(); existing.barPanel = nil
                            existing.originalFrame = actual
                            existing.restoreFrame = actual
                            existing.state = .normal
                            existing.attached = false
                            existing.cooldown = ProcessInfo.processInfo.systemUptime + 2
                        } else { continue }
                    }
                    guard AppListManager.shared.globalSettings.isMasterEnabled, config.isEnabled else { continue }
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
                    if mw.state == .normal { mw.restoreFrame = frame }
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
                    // AXWindows 在 Space/全屏切换期间可能暂时不包含其他 Space 的窗口。
                    // 只有系统明确返回 InvalidUIElement，才把它当作已关闭窗口清理。
                    if mw.needsSessionRecovery {
                        // 列表暂缺但旧句柄仍可读时，也允许恢复；读取失败时保留记录等待下一轮。
                        recoverSessionWindow(key: key, mw: mw)
                    } else if isInvalidWindowElement(mw.axWin) {
                        remove(key, restore: false)
                    }
                }
            }
        }
        for (key, mw) in Array(managed) where NSRunningApplication(processIdentifier: mw.pid) == nil {
            remove(key, restore: false)
        }
        rearrangeBars()
    }

    private func isInvalidWindowElement(_ window: AXUIElement) -> Bool {
        var role: AnyObject?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .invalidUIElement
    }

    private func isVisibleWindowFrame(_ frame: CGRect) -> Bool {
        let area = frame.width * frame.height
        guard area > 0 else { return false }
        return NSScreen.screens.contains { screen in
            let intersection = screen.frame.intersection(frame)
            return !intersection.isNull && intersection.width * intersection.height >= area * 0.2
        }
    }

    private func hide(key: String, mw: ManagedWin, side: HiddenSide) {
        guard session.isAvailable, !mw.needsSessionRecovery, mw.state == .normal else { return }
        // 扫描与鼠标定时器共用最后一道检查，防止旧窗口变成截屏/全屏界面后仍被隐藏。
        guard let from = AnimationEngine.frame(of: mw.axWin) else { return }
        guard WindowEligibility.allows(mw.axWin, frame: from) else {
            remove(key, restore: false)
            return
        }
        mw.side = side
        mw.attached = true
        mw.autoHideAt = nil
        mw.waitForPointerExit = false
        mw.restoreFrame = from
        let usable = NSScreen.screens.first { $0.frame == mw.screenFrame }?.visibleFrame ?? mw.screenFrame
        mw.originalFrame = WindowGeometry.aligned(from, side: side, screen: usable)
        let target = WindowGeometry.hidden(mw.originalFrame, side: side, screen: mw.screenFrame,
                                           peek: AppListManager.shared.globalSettings.peekStripWidth)
        mw.state = .hiding
        let config = AppListManager.shared.config(for: mw.bundleID)
        AnimationEngine.shared.animate(win: mw.axWin, key: key, from: from, to: target,
            type: config.animationType, side: side, screenFrame: mw.screenFrame, isHiding: true) { [weak self, weak mw] in
            guard let self, let mw, self.managed[key] === mw,
                  self.session.isAvailable, !mw.needsSessionRecovery else { return }
            guard AnimationEngine.shared.setAXFrame(target, of: mw.axWin, screenFrame: mw.screenFrame),
                  let actual = AnimationEngine.frame(of: mw.axWin), WindowGeometry.matches(actual, target) else {
                mw.needsSessionRecovery = true
                return
            }
            mw.hiddenFrame = actual
            mw.state = .hidden
            self.createBarPanel(key: key, mw: mw)
        }
    }

    private func createBarPanel(key: String, mw: ManagedWin) {
        guard session.isAvailable, !mw.needsSessionRecovery else { return }
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
        guard session.isAvailable, AppListManager.shared.globalSettings.isMasterEnabled,
              let mw = managed[key], mw.state == .hidden,
              !mw.needsSessionRecovery, !mw.waitForPointerExit,
              AppListManager.shared.config(for: mw.bundleID).isEnabled else { return }
        mw.state = .showing
        mw.barPanel?.close(); mw.barPanel = nil
        let from = AnimationEngine.frame(of: mw.axWin) ?? mw.hiddenFrame ?? mw.originalFrame
        let target = mw.restoreFrame
        let config = AppListManager.shared.config(for: mw.bundleID)
        AnimationEngine.shared.animate(win: mw.axWin, key: key, from: from, to: target,
            type: config.animationType, side: mw.side, screenFrame: mw.screenFrame, isHiding: false) { [weak self, weak mw] in
            guard let self, let mw, self.managed[key] === mw,
                  self.session.isAvailable, !mw.needsSessionRecovery else { return }
            guard self.restoreWindow(mw) else {
                mw.needsSessionRecovery = true
                return
            }
            mw.restoreFrame = AnimationEngine.frame(of: mw.axWin) ?? target
            mw.originalFrame = mw.restoreFrame
            mw.state = .normal
            mw.autoHideAt = nil
            mw.cooldown = ProcessInfo.processInfo.systemUptime + 0.5
            NSRunningApplication(processIdentifier: mw.pid)?.activate(options: [.activateIgnoringOtherApps])
            AXUIElementPerformAction(mw.axWin, kAXRaiseAction as CFString)
        }
    }

    private func handleMouse() {
        let settings = AppListManager.shared.globalSettings
        guard session.isAvailable, settings.isMasterEnabled, AnimationEngine.isTrusted else { return }
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        for (key, mw) in Array(managed) {
            guard !mw.needsSessionRecovery else { continue }
            guard AppListManager.shared.config(for: mw.bundleID).isEnabled else { continue }
            if mw.state == .hidden, mw.waitForPointerExit, let bar = mw.barPanel {
                let zone = WindowGeometry.hotZone(bar: bar.frame, side: mw.side, screen: mw.screenFrame,
                                                 width: settings.hotZoneWidth)
                if !zone.contains(mouse) && !bar.frame.contains(mouse) { mw.waitForPointerExit = false }
                continue
            }
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
