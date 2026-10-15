# 全屏真实窗口可行性验证

这是独立验证工具，尚未接入 EdgeHider 的窗口管理服务。

## 当前实测结果（2026-10-14，macOS 26.5.2 / 25F84）

- `SLSSetWindowLevel` 返回 0，调用进程能读到层级 1000；但独立的已授权观察进程仍读到层级 0，目标窗口也没有出现在当前全屏画面上。因此最初的单进程读回不足以证明真实层级提升成功。
- 可以读取测试窗口的 Space 归属和全屏测试 Space 信息。
- `SLSBridgedMoveWindowsToManagedSpaceOperation` 类可用。其执行函数不是常规导出符号，需查找 Mach-O 符号表；已找到函数地址。
- 在用户授权后通过 LaunchServices 启动控制应用，`AXIsProcessTrusted()` 确认为 true。直接从命令行运行相同可执行文件时为 false，测试报告区分这两种启动方式。
- 已授权情况下调用内部桥接迁移执行函数，目标测试窗口仍属于桌面 Space 1，当前全屏测试 Space 保持不变；先尝试提升浮动层级再迁移同样失败。
- `SLSSetWindowTags` / `SLSClearWindowTags` 对外部测试窗口返回 0，但读取的窗口标记完全不变。分别使用调用进程连接和窗口所属连接进行测试，结果一致；目标窗口仍未显示在全屏画面上。
- 所有目标/全屏测试进程均由验证脚本在结束时关闭。未修改 EdgeHider 的生产窗口管理逻辑，未操作用户的实际应用窗口。

## 结论

当前尝试的独立进程私有接口方案未通过可行性验证。仅能读取 Space 信息和发现接口，不能据此宣称任意第三方窗口可在原生全屏 Space 中交互。真实可见显示阶段失败，所以键盘鼠标操作及迁移后的还原尚未获得验证；窗口本来就在原桌面，不能把这个状态记作“跨 Space 还原成功”。

机器可读报告：`latest-result.json`（授权后的迁移/浮动组合测试）、`latest-tags-result.json`（外部窗口标记测试）。这些结果只描述本次 macOS 26.5.2 上的测试，不排除其他版本、其他内部接口或目标应用主动配合的实现路径。

## 构建和授权

在项目根目录执行 `bash Tools/FullscreenProbe/build.sh`，生成：

- `build/EdgeHiderFullscreenProbe.app`：固定身份的权限验证/控制应用。
- `/tmp/EdgeHiderFullscreenProbe/target.app`：可操作的目标测试窗口。
- `/tmp/EdgeHiderFullscreenProbe/host.app`：原生全屏测试窗口。

启动控制应用并在系统设置 → 隐私与安全性 → 辅助功能中授权。原 EdgeHider 的授权不等于这个独立验证应用的授权。运行 `python3 Tools/FullscreenProbe/run.py` 可重测迁移，`--floating` 可重测浮动组合路径，`--tags --owner` 可重测外部窗口标记。需要有图形桌面访问权限；脚本仅操作它创建的测试窗口。

验证要求：窗口 Space 归属确实变化、当前全屏 Space 保持不变、目标窗口可接收鼠标和键盘操作、隐藏后可还原原 Space 和层级。仅发现符号或调用函数没有报错不能算成功。

## 研究来源

- [yabai 的 Space 管理实现](https://github.com/asmvik/yabai/blob/master/src/space_manager.c)
- `macho_dlsym.h` 来源于 yabai，MIT 许可证与版权声明保存在 `yabai-macho-license.txt`。
