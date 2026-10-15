import Foundation

/// 所有内部几何使用 AppKit 全局坐标；AX 坐标始终以主显示器顶部为基准。
enum WindowGeometry {
    static func matches(_ actual: CGRect, _ target: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(actual.minX - target.minX) <= tolerance && abs(actual.minY - target.minY) <= tolerance
            && abs(actual.width - target.width) <= tolerance && abs(actual.height - target.height) <= tolerance
    }

    static func converted(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func screen(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        screens.max { a, b in
            let x = a.intersection(frame), y = b.intersection(frame)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }
    }

    static func edge(frame: CGRect, screen: CGRect, threshold: CGFloat, preferred: HiddenSide) -> HiddenSide? {
        let distances: [(HiddenSide, CGFloat)] = [
            (.left, abs(frame.minX - screen.minX)), (.right, abs(screen.maxX - frame.maxX)),
            (.bottom, abs(frame.minY - screen.minY)), (.top, abs(screen.maxY - frame.maxY))
        ]
        return distances.filter { preferred == .automatic || $0.0 == preferred }
            .filter { $0.1 <= threshold }.min { $0.1 < $1.1 }?.0
    }

    static func visible(_ frame: CGRect, screen: CGRect) -> CGRect {
        var result = frame
        result.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        result.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        return result
    }

    static func aligned(_ frame: CGRect, side: HiddenSide, screen: CGRect) -> CGRect {
        var result = visible(frame, screen: screen)
        switch side {
        case .left, .automatic: result.origin.x = screen.minX
        case .right: result.origin.x = screen.maxX - frame.width
        case .top: result.origin.y = screen.maxY - frame.height
        case .bottom: result.origin.y = screen.minY
        }
        return result
    }

    static func hidden(_ frame: CGRect, side: HiddenSide, screen: CGRect, peek: CGFloat) -> CGRect {
        var result = frame
        switch side {
        case .left, .automatic: result.origin.x = screen.minX - frame.width + peek
        case .right: result.origin.x = screen.maxX - peek
        case .top: result.origin.y = screen.maxY - peek
        case .bottom: result.origin.y = screen.minY - frame.height + peek
        }
        return result
    }

    static func hotZone(bar: CGRect, side: HiddenSide, screen: CGRect, width: CGFloat) -> CGRect {
        switch side {
        case .left, .automatic: return CGRect(x: screen.minX, y: bar.minY, width: width, height: bar.height)
        case .right: return CGRect(x: screen.maxX - width, y: bar.minY, width: width, height: bar.height)
        case .top: return CGRect(x: bar.minX, y: screen.maxY - width, width: bar.width, height: width)
        case .bottom: return CGRect(x: bar.minX, y: screen.minY, width: bar.width, height: width)
        }
    }
}
