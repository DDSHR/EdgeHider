import AppKit
import ApplicationServices

/// 只管理普通、可移动的文档窗口。截屏遮罩不一定声明 AXFullScreen，
/// 因此还需根据整个显示器（而非仅 visibleFrame）判断覆盖范围。
enum WindowEligibility {
    static func allows(role: String?, subrole: String?, movable: Bool,
                       minimized: Bool, fullScreen: Bool, modal: Bool,
                       frame: CGRect, screenFrames: [CGRect], visibleFrames: [CGRect]) -> Bool {
        guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole,
              movable, !minimized, !fullScreen, !modal,
              frame.width > 80, frame.height > 60 else { return false }
        return !(screenFrames + visibleFrames).contains { screen in
            guard !screen.isEmpty else { return false }
            // 允许少量坐标舍入误差；也排除跨多个显示器的遮罩。
            return frame.minX <= screen.minX + 5 && frame.maxX >= screen.maxX - 5
                && frame.minY <= screen.minY + 5 && frame.maxY >= screen.maxY - 5
        }
    }

    static func allows(_ window: AXUIElement, frame: CGRect) -> Bool {
        func string(_ attribute: String) -> String? {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        var movable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
        return allows(role: string(kAXRoleAttribute), subrole: string(kAXSubroleAttribute),
                      movable: result == .success && movable.boolValue,
                      minimized: AnimationEngine.boolAttribute(kAXMinimizedAttribute, of: window),
                      fullScreen: AnimationEngine.boolAttribute("AXFullScreen", of: window),
                      modal: AnimationEngine.boolAttribute(kAXModalAttribute, of: window),
                      frame: frame, screenFrames: NSScreen.screens.map(\.frame),
                      visibleFrames: NSScreen.screens.map(\.visibleFrame))
    }
}
