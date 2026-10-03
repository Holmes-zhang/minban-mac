# 独立图标提醒 · Beta

任务栏隐藏时，有任务栏按钮的应用请求原生闪烁提醒，其真实图标会从当前按钮位置单独升起，并在约1.2秒后收回。没有任务栏按钮的纯后台、仅托盘应用不会生成浮层。不读取聊天正文或联系人。

组件版本：0.3.0。普通用户使用根目录的“应用民办mac.cmd”，无需编译。开启和关闭入口只控制本包运行目录中的该组件，不影响其他任务栏样式。

## 已知边界

- 触发来自任务栏闪烁信号，只有右下角系统通知而不请求闪烁的应用可能不触发。
- 连续闪烁属于同一轮提醒，不反复弹出，也不延长停留。不同应用分别计时。
- 不支持的内部符号会导致拒绝加载；程序或按钮匹配不明确时保留原生提醒。
- 动画使用固定16毫秒计时节拍，实际帧率取决于系统调度和绘制负载；没有“保证90帧”的选项。
- 本机QQ曾需重启后才恢复提醒，尚未确认全部运行状态都可靠。
- 多屏、不同系统补丁及所有应用未完整实机验证。
- “记录本机排查日志”默认关闭。开启后只记录应用进程名称、组件阶段与图标位置，写入 %LOCALAPPDATA%\MinbanMac\notice.log；没有在线上传。

## 编译对应源码

需要Windows x64和Windhawk 1.7.3完整便携目录。该版本自带的Clang、Windows头文件、Windhawk API及链接库均来自Windhawk安装；本包不再次分发其运行库。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\components\notice\Build-Notice.ps1 -WindhawkDirectory "你的Windhawk便携目录"
```

脚本会构建DLL，并执行去重计时、任务栏窗口匹配和四种缩放下的边框绘制验证。不启动Windhawk、不注入Explorer，不显示测试窗口。测试产物保存在项目 .build/notice-tests。

维护者修改源码后，用额外的 -UpdateManifest 参数刷新对应源码和DLL哈希，再运行 scripts/Build.ps1 生成发布ZIP。源码下载不含已编译DLL，需先完成这一步；普通用户应下载完整Beta切换包。

## 来源与许可

本组件及测试为GPL-3.0-only，完整许可见根目录LICENSE。任务栏闪烁入口的CTaskBand符号名称参考Cirn09的[Better Taskbar Autohide](https://github.com/ramensoftware/windhawk-mods/blob/main/mods/taskbar-autohide-better.wh.cpp)。图标布局匹配、独立浮层及绘制实现为本项目代码。所用Windhawk SDK及运行库保留上游许可，见根目录第三方声明。
