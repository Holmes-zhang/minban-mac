# 上游来源与第三方声明

本项目提供配置预设、运行管理脚本及独立图标提醒组件。底层注入、任务栏样式与动画能力来自以下项目，原作者的名称、项目身份和许可证保持不变。

## Windhawk 1.7.3

- 作者与项目：ramensoftware / m417z
- 项目：https://github.com/ramensoftware/windhawk
- 固定源码：https://github.com/ramensoftware/windhawk/tree/v1.7.3
- 许可全文：https://github.com/ramensoftware/windhawk/blob/v1.7.3/LICENSE
- 许可：GNU GPL version 3。其官方安装包还包含其他组件，各组件仍遵守随上游附带的许可。

本项目不会将官方安装包或安装后的运行库重新放进 ZIP；用户首次运行时下载官方发布资产。

## Windows 11 Taskbar Styler 1.10

- 作者：m417z
- 固定源码：https://mods.windhawk.net/mods/windows-11-taskbar-styler/1.10.wh.cpp
- 上游仓库：https://github.com/ramensoftware/windhawk-mods/blob/main/mods/windows-11-taskbar-styler.wh.cpp
- 固定版本源码的模组元数据声明 GPLv3。

### DockLike 基础主题

DockLike 的原主题作者为 **Amber**。

主题说明：https://github.com/ramensoftware/windows-11-taskbar-styling-guide/blob/main/Themes/DockLike/README.md

本项目选择 Taskbar Styler 中的内置 DockLike，并在其基础上调整圆角、背景、间距、系统托盘及搜索按钮。不是 DockLike 的原作或官方续作。主题在所用 Styler 源码中的实现随该模组获取；没有复制样式指南的截图、壁纸或其他素材。未找到样式指南仓库的独立整体许可，因此不将该仓库宣称为 MIT，也不把本文当作其中全部资源的再分发授权。

## Taskbar height and icon size 1.3.10

- 模组 ID：taskbar-icon-size
- 作者：m417z
- 固定源码：https://mods.windhawk.net/mods/taskbar-icon-size/1.3.10.wh.cpp
- 固定版本源码的模组元数据声明 GPLv3。

## Taskbar auto-hide when maximized 1.2.6

- 作者：m417z
- 固定源码：https://mods.windhawk.net/mods/taskbar-auto-hide-when-maximized/1.2.6.wh.cpp
- 固定版本源码的模组元数据声明 GPLv3。

## Taskbar auto-hide instant show 2.2

- 作者：Bo0ii
- 固定源码：https://mods.windhawk.net/mods/taskbar-autohide-instant-show/2.2.wh.cpp
- 固定版本未在模组元数据中另列许可证。
- 官方提交规则说明：未显式指定许可的模组提交适用 MIT：
  https://github.com/ramensoftware/windhawk-mods#submitting-a-new-mod
- MIT 条款副本见 licenses/MIT.txt；这里按官方默认规则记录，未声称作者额外签发了一份单独许可证。

## 本项目的分发边界

- 新增脚本、文档及预设调整采用 GPL-3.0-only，全文见根目录 LICENSE。
- 发布 ZIP 中不包括第三方二进制，也不包括上述四个模组的源码副本。首次运行时同时取得固定二进制及对应模组源码，并验证清单中的 SHA256。
- 1.1.0-beta.1 起附带本项目独立提醒0.3.0的x64 DLL，同时附带完整对应C++源码、头文件、构建脚本、测试和根目录GPL-3.0-only许可。此组件与四个上游模组在清单中分开列出，不将其宣称为上游作品。
- 独立提醒的CTaskBand闪烁入口符号名称参考Cirn09的[Better Taskbar Autohide](https://github.com/ramensoftware/windhawk-mods/blob/main/mods/taskbar-autohide-better.wh.cpp)。本组件并不打包或替换该上游模组。图标定位、匹配、浮层和绘制实现来自本项目。
- 对应源码位于components/notice/src，构建与测试说明位于components/notice/README.md。使用Windhawk 1.7.3内置编译器及API，Windows系统库在目标系统提供。Windhawk及所含运行库仍从官方安装包获得，保留官方包内的许可；本ZIP没有另附运行库。
- 对应模组源码保存在本机 Cache 和 Runtime/AppData/ModsSource。Windhawk 固定版本源码见前述官方仓库。
- 单独分发或制作离线二进制包时，应另行满足相应许可证的完整要求，包括适用的对应源码和运行库声明。仅保留下载链接不应被视作任何场景下都满足 GPL 二进制分发要求。
- docs/preview.png 为用户提供并授权用于效果展示的桌面截图。截图中的壁纸及应用标识保留各自权利，不因本项目的 GPL 许可而获得独立素材的再分发授权。本包不安装壁纸或图标包。
