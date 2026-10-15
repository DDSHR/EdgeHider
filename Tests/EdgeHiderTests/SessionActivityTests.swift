import XCTest
import AppKit
import ApplicationServices
@testable import EdgeHider

final class SessionActivityTests: XCTestCase {
    private func snapshot(locked: Bool = false, onConsole: Bool = true) -> [String: Any] {
        [kCGSessionOnConsoleKey as String: onConsole, "CGSSessionScreenIsLocked": locked]
    }

    func testDisplayWakeDoesNotResumeWhileScreenStillLocked() {
        let center = NotificationCenter()
        var value = snapshot()
        let monitor = SessionActivityMonitor(workspaceCenter: center, snapshotProvider: { value })
        var changes: [Bool] = []
        monitor.onAvailabilityChanged = { changes.append($0) }
        monitor.start()
        defer { monitor.stop() }

        value = snapshot(locked: true)
        monitor.refresh()
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(monitor.isAvailable)
        XCTAssertEqual(changes, [false])

        value = snapshot()
        monitor.refresh()
        XCTAssertTrue(monitor.isAvailable)
        XCTAssertEqual(changes, [false, true])
    }

    func testSystemSleepAndInactiveSessionMustBothFinish() {
        let center = NotificationCenter()
        let monitor = SessionActivityMonitor(workspaceCenter: center, snapshotProvider: { self.snapshot() })
        var changes: [Bool] = []
        monitor.onAvailabilityChanged = { changes.append($0) }
        monitor.start()
        defer { monitor.stop() }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(monitor.isAvailable)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertTrue(monitor.isAvailable)
        XCTAssertEqual(changes, [false, true])
    }

    func testUnavailableWindowServerSnapshotDoesNotStartRecoveryEarly() {
        let center = NotificationCenter()
        var value: [String: Any]? = snapshot()
        let monitor = SessionActivityMonitor(workspaceCenter: center, snapshotProvider: { value })
        monitor.start()
        defer { monitor.stop() }
        value = nil
        monitor.refresh()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(monitor.isAvailable)
        value = snapshot()
        monitor.refresh()
        XCTAssertTrue(monitor.isAvailable)
    }

    func testPollingDetectsLockUnlockWithoutWorkspaceNotifications() {
        var value = snapshot()
        let monitor = SessionActivityMonitor(workspaceCenter: NotificationCenter(), snapshotProvider: { value })
        var changes: [Bool] = []
        monitor.onAvailabilityChanged = { changes.append($0) }
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<2 {
            value = snapshot(locked: true)
            monitor.refresh()
            monitor.refresh()
            value = snapshot()
            monitor.refresh()
        }
        XCTAssertEqual(changes, [false, true, false, true])
    }

    func testSwitchingAwayFromConsolePausesUntilConsoleReturns() {
        var value = snapshot(onConsole: false)
        let monitor = SessionActivityMonitor(workspaceCenter: NotificationCenter(), snapshotProvider: { value })
        monitor.start()
        defer { monitor.stop() }
        XCTAssertFalse(monitor.isAvailable)
        value = snapshot()
        monitor.refresh()
        XCTAssertTrue(monitor.isAvailable)
    }

    func testStopRemovesWorkspaceObserversAndIgnoresQueuedEvents() {
        let center = NotificationCenter()
        let monitor = SessionActivityMonitor(workspaceCenter: center, snapshotProvider: { self.snapshot() })
        var changes: [Bool] = []
        monitor.onAvailabilityChanged = { changes.append($0) }
        monitor.start()
        monitor.start()
        monitor.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        monitor.refresh()
        XCTAssertTrue(changes.isEmpty)
        monitor.start()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(changes, [false])
        monitor.stop()
    }

    func testLockNotificationRemainsPausedWhileSnapshotIsStale() {
        let center = NotificationCenter()
        let monitor = SessionActivityMonitor(workspaceCenter: center, snapshotProvider: { self.snapshot() })
        var changes: [Bool] = []
        monitor.onAvailabilityChanged = { changes.append($0) }
        monitor.start()
        defer { monitor.stop() }
        monitor.handleScreenLock(true)
        monitor.handleScreenLock(true)
        monitor.refresh()
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(monitor.isAvailable)
        XCTAssertEqual(changes, [false])
        monitor.handleScreenLock(false)
        monitor.handleScreenLock(false)
        XCTAssertTrue(monitor.isAvailable)
        XCTAssertEqual(changes, [false, true])
    }

    func testObservedSnapshotUnlockRecoversMissedUnlockNotification() {
        var value = snapshot()
        let monitor = SessionActivityMonitor(workspaceCenter: NotificationCenter(), snapshotProvider: { value })
        monitor.start()
        defer { monitor.stop() }
        monitor.handleScreenLock(true)
        value = snapshot(locked: true)
        monitor.refresh()
        value = snapshot()
        monitor.refresh()
        XCTAssertTrue(monitor.isAvailable)
    }
}
