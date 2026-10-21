# zmd-mac

为《明日方舟：终末地》的官方启动器提供 macOS 安装包，支持国服和 Global。

需要 **macOS 27+、Rosetta 2**。安装包内置 Wine 和图形转译组件，无需 Python、Homebrew 或 Windows 虚拟机。

## 安装

从 [Releases](https://github.com/shiftz300/zmd-mac/releases/latest) 下载：

- **PKG**：双击安装，在「安装类型 → 自定」选择国服或 Global，也可同时安装。
- **ZIP**：解压后双击 `安装终末地.command`，或在终端运行 `./zmd setup`。可下载官方启动器或选择本地安装 EXE。

安装完成后，打开 `~/Applications/鹰角启动器.app`（国服）或 `~/Applications/GRYPHLINK.app`（Global），下载并启动游戏。
两服的游戏目录和登录状态独立，已有同名应用不会被覆盖。
安装后，应用列表显示官方启动器名称和图标；设置集成在启动器内。只有桌面入口使用替身。

旧版的「终末地.app」或「终末地 Global.app」可继续使用；发现旧入口时，默认安装会停止，避免重复安装。

PKG 需要管理员授权和网络连接。安装包尚未公证，如被系统拦截，请在「隐私与安全性」中允许打开。
未安装 Rosetta 时，按提示完成安装。

### 命令行

在 ZIP 解压目录运行，保持 `zmd` 与 `payload` 同目录：

```sh
./zmd install --desktop
./zmd install --region global --desktop

# 使用本地官方启动器安装包
./zmd install --exe "/路径/HypergryphLauncher.exe" --desktop
./zmd install --region global --exe "/路径/GRYPHLINK.exe" --desktop
```

请使用官方启动器安装包，不能直接导入 `Endfield.exe`。

## 运行设置

默认使用 **Vulkan、窗口模式和 MSync**。打开应用时会显示原生设置窗口，也可选择左上角应用菜单中的「运行设置…」，或按 **⌘,** 打开。
窗口左下角实时显示启动器或游戏的运行状态；启动期间显示等待指示。

- 切换 Vulkan / DXMT / DXMT + MetalFX、MSync 和 Metal 性能面板。
- 「显示」页设置窗口／无边框全屏、启动分辨率；支持预设、自定义和读取设置窗口所在屏幕的原生像素分辨率，不受 macOS 桌面缩放影响。默认使用游戏分辨率。
- 调整 Vulkan 队列、日志和调试选项；装有实验库时可切换 MoltenVK 版本。
- 在「调试」页清除 Vulkan 缓存：正常退出会话后清理并重开启动器；首次进入游戏可能重新编译着色器。退出未完成则取消清理。
- 可关闭「打开启动器时显示设置」。保存运行设置后，可选择立即重启启动器；取消则保留设置，下次启动生效。

重启会先正常退出游戏和启动器，再打开官方启动器，游戏需再次点击「开始游戏」。若游戏取消退出或未能退出，本次重启也会取消。

换屏后可把设置窗口移到目标屏幕，点击「读取当前屏幕」并保存重启。读取的是原生像素尺寸，例如内建屏的 3024×1964，而非「看起来像」的 1512×982；无法识别时请手动选择。此操作不移动游戏窗口。

自定义分辨率会在会话启动时同步到游戏的分辨率配置，原值单独备份。选择「使用游戏设置」可停止覆盖，保留游戏当前值。游戏下拉菜单可能不列出自定义尺寸；最终输出仍需在游戏中确认。

游戏画质在游戏内调整。Dock 的「退出」会依次关闭游戏和官方启动器。

```sh
# 查看配置
./zmd inspect --app "$HOME/Applications/鹰角启动器.app"

# 恢复稳定版 Vulkan 和默认队列
./zmd configure --app "$HOME/Applications/鹰角启动器.app" --renderer vulkan --moltenvk stable --vulkan-queue default
```

Vulkan 下部分场景的 FSR 可能出现黑纹，可改用 TAAU。DXMT + MetalFX 通过游戏的 DLSS 选项使用，不支持 DLSS 帧生成；实际性能因场景而异。
MoltenVK 实验版需[单独构建](docs/building.md#可选-moltenvk-实验版)，默认安装包不包含。

游戏和登录状态保存在应用内部。备份时先退出，再复制整个应用；升级时不要直接覆盖已有应用。

## 开发与发布

开发需要 Apple Silicon、macOS 27、Rosetta 2、Command Line Tools 和 Git，不需要 Python。

```sh
swift run zmd-dev test
ZMD_WORK_DIR="$PWD/.work" swift run zmd-dev build
```

安装、启动、构建和测试使用 Swift；PKG 钩子和 ZIP 双击入口保留简短 Shell。产物输出到 `release/`。详细步骤见[构建说明](docs/building.md)。

CI 在分支推送时构建，PR 执行快速检查。推送与应用版本一致的 `vX.Y.Z` 标签会自动发布 Release；带 `-rc.1` 等后缀的标签发布为预发布版。
Release 提供 PKG、CLI ZIP 和第三方源码包。项目源码使用 GitHub 自带下载，SHA-256 在发布前校验，不另上传校验文件。

## 文档

- [运行环境](docs/configuration.md)
- [性能调优](docs/tuning.md)
- [排障](docs/troubleshooting.md)
- [验证记录](docs/verification.md)
- [第三方组件与许可证](THIRD_PARTY_NOTICES.md)

非官方项目，不包含游戏文件或账号数据。国服已在 M5 Pro / macOS 27.0.1 上验证运行，Global 完整游玩尚未验证；游戏更新可能影响兼容性。
项目代码采用 MIT，第三方组件遵循各自许可证。
