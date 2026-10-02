# 维护说明

此文面向维护者；日常使用见根目录 README。

## 文件与运行数据

scripts/Core.ps1 负责下载、配置、备份及恢复，Launcher.ps1 提供入口。presets 存放四个模组设置，dependencies.json 固定版本、官方下载地址与程序及对应源码 SHA256。

运行数据放在 %LOCALAPPDATA%\MinbanMac：

| 目录或文件 | 用途 |
| --- | --- |
| Runtime | 独立便携 Windhawk 与模组 |
| Cache | 校验过的官方下载文件 |
| Backups | 原启动快捷方式备份 |
| state.json | 含个人原路径的本机恢复记录 |
| network.local.json | 本机代理设置 |

不要将这些运行数据放进公开仓库。项目的忽略规则已排除常见运行数据；发布包按明确文件清单生成。

## 检查与构建

在项目目录使用系统自带的 64 位 Windows PowerShell 5.1：

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Validate.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1

也可通过 Build.ps1 的 OutputDirectory 参数指定输出目录。同名发布包已存在时不覆盖，请先保留旧包或指定新目录。

修改 PowerShell 文件后保留 UTF-8 BOM，确保 Windows PowerShell 5.1 正确读取中文。生成的 Windhawk INI 使用 UTF-16 LE。

更换依赖版本时同步更新程序、源码地址与 SHA256，核实元数据及许可，再重新验证。

## 分享边界

源码仓库不包含第三方程序。官方组件在用户本机下载，同时获取对应模组源码。另行制作离线二进制包时，应重新满足对应源码与各运行库许可要求。

docs/preview.png 是用户授权用于项目效果展示的桌面截图；壁纸和应用标识仍保留各自权利，不作为 GPL 壁纸或图标素材包分发。

上游完整署名、许可依据和固定版本源码见 THIRD-PARTY-NOTICES.md。实现与验证范围分别见 ARCHITECTURE.md 和 VALIDATION.md。
