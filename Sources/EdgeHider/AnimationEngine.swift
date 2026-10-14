import Foundation
import AppKit
import ApplicationServices

final class AnimationEngine {
    static let shared = AnimationEngine()
    private var activeAnimations: [String: Timer] = [:]

    private init() {}

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(options)
    }

    // AX 的全局坐标以主显示器左上角为原点，不能按目标显示器翻转。
    private static var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func boolAttribute(_ name: String, of win: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(win, name as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    static func frame(of win: AXUIElement) -> CGRect? {
        var position: AnyObject?
        var size: AnyObject?
        guard !NSScreen.screens.isEmpty,
              AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return WindowGeometry.converted(CGRect(origin: point, size: dimensions), primaryTop: primaryTop)
    }

    func setAXFrame(_ frame: CGRect, of win: AXUIElement, screenFrame: CGRect) {
        var size = frame.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, value)
        }
        // 应用可能限制最小尺寸，使用实际高度计算位置。
        let actualSize = Self.frame(of: win)?.size ?? frame.size
        var point = WindowGeometry.converted(CGRect(origin: frame.origin, size: actualSize), primaryTop: Self.primaryTop).origin
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, value)
        }
    }

    func forceHidePosition(_ frame: CGRect, of win: AXUIElement, screenFrame: CGRect) {
        setAXFrame(frame, of: win, screenFrame: screenFrame)
    }

    private func setAXPosition(_ point: CGPoint, of win: AXUIElement, screenFrame: CGRect) {
        guard let current = Self.frame(of: win) else { return }
        var axPoint = WindowGeometry.converted(CGRect(origin: point, size: current.size), primaryTop: Self.primaryTop).origin
        guard let value = AXValueCreate(.cgPoint, &axPoint) else { return }
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, value)
    }

    private func setAXFrame(origin: CGPoint, size: CGSize, of win: AXUIElement, screenFrame: CGRect) {
        setAXFrame(CGRect(origin: origin, size: size), of: win, screenFrame: screenFrame)
    }

    // MARK: - 动画
    func animate(win: AXUIElement,
                 key: String,
                 from fromFrame: CGRect,
                 to toFrame: CGRect,
                 type: AnimationType,
                 side: HiddenSide,
                 screenFrame: CGRect,
                 isHiding: Bool,
                 completion: (() -> Void)? = nil) {
        activeAnimations[key]?.invalidate()
        activeAnimations[key] = nil

        switch type {
        case .instant:
            setAXPosition(toFrame.origin, of: win, screenFrame: screenFrame)
            completion?()
        case .spring:
            runSpring(key: key, win: win, from: fromFrame.origin, to: toFrame.origin, screenFrame: screenFrame, completion: completion)
        case .slide:
            runSlide(key: key, win: win, from: fromFrame.origin, to: toFrame.origin, screenFrame: screenFrame, duration: 0.3, completion: completion)
        case .genie:
            runSlide(key: key, win: win, from: fromFrame.origin, to: toFrame.origin, screenFrame: screenFrame, duration: 0.5, completion: completion)
        case .fade:
            runSlide(key: key, win: win, from: fromFrame.origin, to: toFrame.origin, screenFrame: screenFrame, duration: 0.6, completion: completion)
        case .jelly:
            runJelly(key: key, win: win, from: fromFrame.origin, to: toFrame.origin, screenFrame: screenFrame, completion: completion)
        case .scale:
            runScale(key: key, win: win, from: fromFrame, to: toFrame, side: side, screenFrame: screenFrame, isHiding: isHiding, completion: completion)
        case .flip:
            runFlip(key: key, win: win, from: fromFrame, to: toFrame, side: side, screenFrame: screenFrame, isHiding: isHiding, completion: completion)
        }
    }

    private func runSlide(key: String, win: AXUIElement, from start: CGPoint, to end: CGPoint, screenFrame: CGRect, duration: TimeInterval, completion: (() -> Void)?) {
        let t0 = ProcessInfo.processInfo.systemUptime
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            let p = min((ProcessInfo.processInfo.systemUptime - t0)/duration, 1.0)
            let e = CGFloat(p < 0.5 ? 2*p*p : 1 - pow(-2*p+2, 2)/2)
            let x = start.x + (end.x - start.x)*e
            let y = start.y + (end.y - start.y)*e
            self?.setAXPosition(CGPoint(x: x, y: y), of: win, screenFrame: screenFrame)
            if p >= 1.0 { t.invalidate(); self?.activeAnimations[key] = nil; completion?() }
        }
        activeAnimations[key] = timer
    }

    private func runSpring(key: String, win: AXUIElement, from start: CGPoint, to end: CGPoint, screenFrame: CGRect, completion: (() -> Void)?) {
        let duration: TimeInterval = 0.8
        let t0 = ProcessInfo.processInfo.systemUptime
        let dx = end.x - start.x
        let dy = end.y - start.y
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            let elapsed = (ProcessInfo.processInfo.systemUptime - t0)
            let progress = min(elapsed/duration, 1.0)
            let tt = CGFloat(elapsed)
            // 过冲弹簧：先冲过头 20%，再弹回来
            let overshoot: CGFloat = 0.2
            let decay = exp(-3.0 * tt)
            let wobble = sin(tt * 10.0) * decay * overshoot
            var p: CGFloat = CGFloat(progress < 0.5 ? 2*progress*progress : 1 - pow(-2*progress+2, 2)/2) + wobble
            if progress >= 1.0 { p = 1.0 }
            p = max(-0.05, min(1.15, p))
            let x = start.x + dx*p
            let y = start.y + dy*p
            self?.setAXPosition(CGPoint(x: x, y: y), of: win, screenFrame: screenFrame)
            if elapsed >= duration {
                t.invalidate()
                self?.setAXPosition(end, of: win, screenFrame: screenFrame)
                self?.activeAnimations[key] = nil
                completion?()
            }
        }
        activeAnimations[key] = timer
    }

    private func runJelly(key: String, win: AXUIElement, from start: CGPoint, to end: CGPoint, screenFrame: CGRect, completion: (() -> Void)?) {
        let duration: TimeInterval = 0.9
        let t0 = ProcessInfo.processInfo.systemUptime
        let dx = end.x - start.x
        let dy = end.y - start.y
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            let elapsed = (ProcessInfo.processInfo.systemUptime - t0)
            let p = min(elapsed/duration, 1.0)
            let tt = CGFloat(elapsed)
            // 果冻：大幅高频振荡衰减
            let decay = exp(-2.5 * tt)
            let wobble = sin(tt * 15.0) * decay
            let base = CGFloat(p < 0.5 ? 2*p*p : 1 - pow(-2*p+2, 2)/2)
            var v = base + wobble * 0.25
            if p >= 1.0 { v = 1.0 }
            v = max(-0.1, min(1.1, v))
            let x = start.x + dx*v
            let y = start.y + dy*v
            self?.setAXPosition(CGPoint(x: x, y: y), of: win, screenFrame: screenFrame)
            if elapsed >= duration {
                t.invalidate()
                self?.setAXPosition(end, of: win, screenFrame: screenFrame)
                self?.activeAnimations[key] = nil
                completion?()
            }
        }
        activeAnimations[key] = timer
    }

    private func runScale(key: String, win: AXUIElement, from fromFrame: CGRect, to toFrame: CGRect, side: HiddenSide, screenFrame: CGRect, isHiding: Bool, completion: (() -> Void)?) {
        let duration: TimeInterval = 0.35
        let t0 = ProcessInfo.processInfo.systemUptime
        let full = isHiding ? fromFrame.size : toFrame.size
        let small = CGSize(width: full.width*0.05, height: full.height*0.05)
        let sz0 = isHiding ? full : small
        let sz1 = isHiding ? small : full
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            let p = min((ProcessInfo.processInfo.systemUptime - t0)/duration, 1.0)
            let e = CGFloat(p < 0.5 ? 2*p*p : 1 - pow(-2*p+2, 2)/2)
            let x = fromFrame.origin.x + (toFrame.origin.x - fromFrame.origin.x)*e
            let y = fromFrame.origin.y + (toFrame.origin.y - fromFrame.origin.y)*e
            let w = sz0.width + (sz1.width - sz0.width)*e
            let h = sz0.height + (sz1.height - sz0.height)*e
            self?.setAXFrame(origin: CGPoint(x: x, y: y), size: CGSize(width: w, height: h), of: win, screenFrame: screenFrame)
            if p >= 1.0 { t.invalidate(); self?.activeAnimations[key] = nil; completion?() }
        }
        activeAnimations[key] = timer
    }

    private func runFlip(key: String, win: AXUIElement, from fromFrame: CGRect, to toFrame: CGRect, side: HiddenSide, screenFrame: CGRect, isHiding: Bool, completion: (() -> Void)?) {
        let duration: TimeInterval = 0.4
        let t0 = ProcessInfo.processInfo.systemUptime
        let compressW = (side == .left || side == .right)
        let full = isHiding ? fromFrame.size : toFrame.size
        let thin = CGSize(width: compressW ? full.width*0.02 : full.width, height: compressW ? full.height : full.height*0.02)
        let sz0 = isHiding ? full : thin
        let sz1 = isHiding ? thin : full
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            let p = min((ProcessInfo.processInfo.systemUptime - t0)/duration, 1.0)
            let e = CGFloat(p*p)
            let x = fromFrame.origin.x + (toFrame.origin.x - fromFrame.origin.x)*e
            let y = fromFrame.origin.y + (toFrame.origin.y - fromFrame.origin.y)*e
            let w = sz0.width + (sz1.width - sz0.width)*e
            let h = sz0.height + (sz1.height - sz0.height)*e
            self?.setAXFrame(origin: CGPoint(x: x, y: y), size: CGSize(width: w, height: h), of: win, screenFrame: screenFrame)
            if p >= 1.0 { t.invalidate(); self?.activeAnimations[key] = nil; completion?() }
        }
        activeAnimations[key] = timer
    }

    func stopAnimation(key: String) {
        activeAnimations[key]?.invalidate()
        activeAnimations[key] = nil
    }
}
