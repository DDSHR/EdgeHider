import AppKit
import ApplicationServices

/// 唤醒显示器并不等于解锁；所有暂停原因都解除后才允许操作窗口。
struct SessionActivityState {
    enum Reason: Hashable {
        case screenLocked, snapshotLocked, sessionInactive, offConsole
        case displayAsleep, systemAsleep, snapshotUnavailable
    }

    private(set) var reasons = Set<Reason>()
    var isAvailable: Bool { reasons.isEmpty }

    mutating func set(_ reason: Reason, suspended: Bool) {
        if suspended { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}

final class SessionActivityMonitor: NSObject {
    var onAvailabilityChanged: ((Bool) -> Void)?
    private(set) var state = SessionActivityState()
    var isAvailable: Bool { state.isAvailable }
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var sawLockedSnapshot = false
    private let workspaceCenter: NotificationCenter
    private let snapshotProvider: () -> [String: Any]?
    private let locked = Notification.Name("com.apple.screenIsLocked")
    private let unlocked = Notification.Name("com.apple.screenIsUnlocked")

    init(workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         snapshotProvider: @escaping () -> [String: Any]? = {
             CGSessionCopyCurrentDictionary() as? [String: Any]
         }) {
        self.workspaceCenter = workspaceCenter
        self.snapshotProvider = snapshotProvider
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        let center = workspaceCenter
        let events: [(Notification.Name, SessionActivityState.Reason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemAsleep, true),
            (NSWorkspace.didWakeNotification, .systemAsleep, false),
            (NSWorkspace.screensDidSleepNotification, .displayAsleep, true),
            (NSWorkspace.screensDidWakeNotification, .displayAsleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false)
        ]
        for (name, reason, suspended) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.running else { return }
                var next = self.state
                next.set(reason, suspended: suspended)
                // 在同一次状态提交中核对锁屏，避免显示器亮起时提前恢复。
                self.updateSnapshot(&next)
                self.commit(next)
            })
        }
        // 普通锁屏未必切换用户会话，也未必让显示器休眠；补充系统锁屏通知。
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockChanged(_:)),
            name: locked, object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockChanged(_:)),
            name: unlocked, object: nil, suspensionBehavior: .deliverImmediately)
        refresh()
    }

    func stop() {
        running = false
        for observer in observers { workspaceCenter.removeObserver(observer) }
        observers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
        state = SessionActivityState()
        sawLockedSnapshot = false
    }

    /// 扫描心跳核对状态，补偿可能错过的锁屏通知。
    func refresh() {
        guard running else { return }
        var next = state
        updateSnapshot(&next)
        commit(next)
    }

    @objc private func lockChanged(_ notification: Notification) {
        let apply = { [weak self] in
            guard let self else { return }
            self.handleScreenLock(notification.name == self.locked)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func handleScreenLock(_ isLocked: Bool) {
        guard running else { return }
        var next = state
        updateSnapshot(&next)
        next.set(.screenLocked, suspended: isLocked)
        commit(next)
    }

    private func updateSnapshot(_ next: inout SessionActivityState) {
        guard let snapshot = snapshotProvider() else {
            next.set(.snapshotUnavailable, suspended: true)
            return
        }
        next.set(.snapshotUnavailable, suspended: false)
        let onConsole = (snapshot[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue ?? false
        next.set(.offConsole, suspended: !onConsole)
        // 只读取系统状态；此补充字段不是公开 API，工作区通知仍单独保留。
        let isLocked = (snapshot["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        next.set(.snapshotLocked, suspended: isLocked)
        if isLocked {
            sawLockedSnapshot = true
        } else if sawLockedSnapshot {
            // 已确实观察到“锁定 -> 解锁”，即使漏掉解锁通知也能继续运行。
            sawLockedSnapshot = false
            next.set(.screenLocked, suspended: false)
        }
    }

    private func commit(_ next: SessionActivityState) {
        let changed = state.isAvailable != next.isAvailable
        state = next
        if changed { onAvailabilityChanged?(next.isAvailable) }
    }
}
