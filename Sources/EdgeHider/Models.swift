import Foundation
import AppKit

// MARK: - 隐藏方向
enum HiddenSide: String, Codable, CaseIterable {
    case left, right, top, bottom
    case automatic  // 自动根据窗口靠近的边缘判断

    var displayName: String {
        switch self {
        case .left: return "左侧"
        case .right: return "右侧"
        case .top: return "顶部"
        case .bottom: return "底部"
        case .automatic: return "自动检测"
        }
    }
}

// MARK: - 动画效果类型
enum AnimationType: String, Codable, CaseIterable {
    case spring      // 弹簧效果
    case genie       // 苹果神奇效果（聚宝盆近似）
    case slide       // 伸缩滑动
    case fade        // 淡入淡出
    case jelly       // 果冻晃动
    case scale       // 缩放收缩
    case flip        // 翻转入场
    case instant     // 瞬间切换（无动画）

    var displayName: String {
        switch self {
        case .spring:  return "弹簧效果"
        case .genie:   return "舒缓滑动"
        case .slide:   return "伸缩滑动"
        case .fade:    return "柔和滑动"
        case .jelly:   return "果冻晃动"
        case .scale:   return "缩放收缩"
        case .flip:    return "翻转入场"
        case .instant: return "瞬间切换"
        }
    }

    var description: String {
        switch self {
        case .spring:  return "带阻尼回弹的物理弹簧动画"
        case .genie:   return "较慢的平滑滑动（保留旧 Genie 配置兼容）"
        case .slide:   return "平滑滑动进出屏幕边缘"
        case .fade:    return "延长过渡时间的柔和滑动"
        case .jelly:   return "果冻般多段晃动回弹"
        case .scale:   return "窗口边滑出边缩小尺寸"
        case .flip:    return "窗口翻页式压扁展开"
        case .instant: return "立即隐藏 / 弹出，无过渡"
        }
    }
}

// MARK: - 单个应用的配置
struct AppConfig: Codable, Equatable {
    var bundleIdentifier: String
    var appName: String
    var isEnabled: Bool
    var animationType: AnimationType
    var hiddenSide: HiddenSide
    /// 窗口吸附边缘的触发距离（点），越大越容易触发
    var edgeThreshold: CGFloat
    /// 旧配置兼容字段；自动隐藏统一使用全局 autoHideDelay。
    var autoHideDelayMs: Int

    static let `default` = AppConfig(
        bundleIdentifier: "",
        appName: "",
        isEnabled: false,
        animationType: .spring,
        hiddenSide: .automatic,
        edgeThreshold: 12.0,
        autoHideDelayMs: 400
    )
}

// MARK: - 全局设置
struct GlobalSettings: Codable {
    /// 全局开关
    var isMasterEnabled: Bool
    /// 热区宽度（鼠标靠近边缘多少像素内触发弹出）
    var hotZoneWidth: CGFloat
    /// 隐藏时露出的边条宽度（像素，0 = 完全隐藏）
    var peekStripWidth: CGFloat
    /// 是否在启动时登录
    var launchAtLogin: Bool

    /// 鼠标移开后自动隐藏延迟（秒）
    var autoHideDelay: TimeInterval

    static let `default` = GlobalSettings(
        isMasterEnabled: true,
        hotZoneWidth: 6.0,
        peekStripWidth: 0.0,
        launchAtLogin: false,
        autoHideDelay: 1.5
    )
}

// MARK: - 配置导出文件格式
struct ConfigFile: Codable {
    var version: Int
    var exportedAt: Date
    var globalSettings: GlobalSettings
    var appConfigs: [String: AppConfig]

    static let currentVersion = 1
}

// 兼容旧版本缺少字段的配置，避免新增设置后整份配置被丢弃。
extension GlobalSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = .default
        isMasterEnabled = try c.decodeIfPresent(Bool.self, forKey: .isMasterEnabled) ?? isMasterEnabled
        hotZoneWidth = try c.decodeIfPresent(CGFloat.self, forKey: .hotZoneWidth) ?? hotZoneWidth
        peekStripWidth = try c.decodeIfPresent(CGFloat.self, forKey: .peekStripWidth) ?? peekStripWidth
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        autoHideDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .autoHideDelay) ?? autoHideDelay
        guard (2...20).contains(hotZoneWidth), (0...30).contains(peekStripWidth),
              (0...60).contains(autoHideDelay) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "全局设置数值超出范围"))
        }
    }
}

extension AppConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = .default
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? bundleIdentifier
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        animationType = try c.decodeIfPresent(AnimationType.self, forKey: .animationType) ?? animationType
        hiddenSide = try c.decodeIfPresent(HiddenSide.self, forKey: .hiddenSide) ?? hiddenSide
        edgeThreshold = try c.decodeIfPresent(CGFloat.self, forKey: .edgeThreshold) ?? edgeThreshold
        autoHideDelayMs = try c.decodeIfPresent(Int.self, forKey: .autoHideDelayMs) ?? autoHideDelayMs
        guard !bundleIdentifier.isEmpty, (1...100).contains(edgeThreshold), (0...60000).contains(autoHideDelayMs) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "应用设置数值无效"))
        }
    }
}

extension ConfigFile {
    func validate() throws {
        guard version == Self.currentVersion else {
            throw NSError(domain: "EdgeHider.Config", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的配置文件版本：\(version)"])
        }
        guard appConfigs.allSatisfy({ $0.key == $0.value.bundleIdentifier }) else {
            throw NSError(domain: "EdgeHider.Config", code: 2, userInfo: [NSLocalizedDescriptionKey: "应用标识与配置键不一致"])
        }
    }
}
