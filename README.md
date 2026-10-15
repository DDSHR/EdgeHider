# EdgeHider — macOS 窗口边缘自动隐藏工具

把任意应用的窗口拖到屏幕边缘，它会自动缩进屏幕外；鼠标再靠近那条边，窗口又自动弹出来。复刻老版 PC QQ 桌面边栏的体验，并做成"万能版"——自由选择对哪些应用生效、每个应用配不同动画。

**当前版本 v1.1.4**

1.1.4 增加锁屏/唤醒后的窗口状态恢复。29 项自动化测试通过；真实锁屏/解锁场景仍需实机回归。

**已知限制**：在其他应用的原生全屏 Space 内直接操作第三方真实窗口仍未实现，目前唤回可能切换桌面。相关求助见 [Issue #1](https://github.com/DDSHR/EdgeHider/issues/1)，实验代码与结果见 [FullscreenProbe](Tools/FullscreenProbe/README.md)。

稳定性修复与兼容性说明见 [CHANGELOG.md](CHANGELOG.md)。

运行回归测试：`swift test`。

## v1.1 新增

- 🖥️ **多显示器支持**：每个屏幕独立检测边缘，窗口在哪个屏就藏哪个屏的边，鼠标在哪屏就触发哪屏的热区
- 🎬 **三种新动画**：
  - **果冻晃动**：高频小振幅振荡，像果冻 Q 弹
  - **缩放收缩**：窗口边滑出边缩小尺寸
  - **翻转入场**：沿边缘压扁展开，模拟翻页
- 🔐 **开机自启**：基于 `SMAppService`（macOS 13+），设置里一键开关
- 📦 **配置导入 / 导出**：一键把所有应用配置和全局设置存成 JSON 文件，换电脑或备份直接导入

## 已有功能

- 🖱️ 自由勾选应用
- 🎬 弹簧 / 舒缓滑动 / 滑动 / 柔和滑动 / 瞬间切换
- 📐 方向自适应（自动 / 固定四边）
- 🎛️ 可调热区宽度、露出边条、吸附灵敏度、自动隐藏延时
- 📋 菜单栏常驻，配置自动保存

## 系统要求

- **macOS 13.0 (Ventura) 或更高**（开机自启功能需要）
- 已安装 Xcode 命令行工具（`xcode-select --install`）
- 需要授予**辅助功能（Accessibility）权限**

## 在你的 Mac 上构建

需要 macOS、Swift 5.9 或更新版本及 Xcode 命令行工具。克隆仓库后运行：

```bash
git clone https://github.com/DDSHR/EdgeHider.git
cd EdgeHider
./build_app.sh
open build/EdgeHider.app
```

脚本会在 `build/EdgeHider.app` 生成应用包；构建产物不会提交到仓库。运行测试：`swift test`。

> 第一次启动会弹出设置窗口并引导你去 **系统设置 → 隐私与安全性 → 辅助功能** 勾选 EdgeHider。授权后点"刷新状态"。

## 使用

1. 菜单栏点 EdgeHider 图标 → **打开设置…**
2. 在应用列表里勾选要启用边缘隐藏的程序
3. 给每个应用选动画效果（8 种）和方向
4. 把窗口拖到屏幕边缘，自动隐藏；鼠标靠近边缘，自动弹出
5. 全局设置里可以开"开机自动启动"、"导出配置"备份

## 项目结构

```
EdgeHider/
├── Package.swift
├── build_app.sh
├── Sources/EdgeHider/
│   ├── main.swift                  # 菜单栏 App 入口
│   ├── Models.swift                # 数据模型 + 配置文件格式
│   ├── AppListManager.swift        # 应用列表 + 配置持久化 + 导入导出
│   ├── AnimationEngine.swift        # AX API + 8 种动画
│   ├── EdgeHiderService.swift      # 窗口扫描 / 边缘检测 / 热区（多屏）
│   ├── WindowGeometry.swift       # 多屏坐标和四边几何计算
│   ├── EdgeBarPanel.swift          # 边缘恢复标签
│   ├── SettingsView.swift         # SwiftUI 设置界面
│   └── LaunchAtLoginManager.swift # SMAppService 开机自启
└── README.md
```

## 许可证

本项目使用 [MIT License](LICENSE)。

## 常见问题

**Q: 为什么我拖窗口到边缘它不动？**
A: 99% 是辅助功能权限没给。去 系统设置 → 隐私与安全性 → 辅助功能，确认 EdgeHider 是打开的。改完后菜单栏点"重新扫描窗口"。

**Q: 多显示器怎么算？**
A: 窗口在哪个屏，就按那个屏的边缘来检测；鼠标在哪个屏，就触发那个屏上隐藏的窗口。不同屏独立管理；相邻屏幕的共享边缘可能把窗口移到另一块屏幕，建议使用桌面的外侧边缘。

**Q: 缩放和翻转动画会改坏窗口布局吗？**
A: 这两个动画会临时调整窗口大小，结束后恢复原始尺寸。大部分 App 能正常适应；如果某个 App 对 resize 反应异常，换用弹簧或滑动即可。

**Q: 开机自启开关灰掉/报错？**
A: 需要 macOS 13+。并且应用必须在 `/Applications` 目录里（SMAppService 要求），先把 EdgeHider.app 拖进 /Applications 再开。

隐藏延迟统一使用菜单中的全局设置；旧配置的 `autoHideDelayMs` 字段仅为兼容保留。固定方向表示只在对应边缘触发，鼠标热区宽度控制每个标签对应的边缘唤出范围，直接悬停标签也可恢复窗口。
