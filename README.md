# zmd-mac

把终末地国服／Global 官方启动器安装为可双击的 macOS 应用。面向 **Apple Silicon、macOS 27+、已安装 Rosetta 2**。

预构建包内置 Wine、Vulkan/MoltenVK、DXMT 和解包工具，使用者不需要 Python、Homebrew、Xcode 或 Windows 虚拟机。Python 和编译工具只用于开发／CI 构建。

这是非官方兼容性项目。游戏、官方启动器、账号和游戏资源由鹰角提供；项目没有打包已安装游戏或用户登录状态。当前已有人在 M5 Pro / macOS 27.0.1 上从官方启动器进入国服，不能据此保证每次游戏更新或完整反作弊流程都兼容。

## 使用预构建包

从 [GitHub Releases](https://github.com/shiftz300/zmd-mac/releases) 下载 PKG 或 ZIP。
如果尚无已发布版本，可在 [Build 工作流](https://github.com/shiftz300/zmd-mac/actions/workflows/build.yml)
的成功运行中下载 `zmd-mac-macos-arm64` artifact，解压后选择 PKG 或 ZIP。
Release 同时提供 SHA-256 校验文件、项目源码和第三方源码；本地构建成功不代表线上产物已经生成。

### PKG（图形安装）

双击 `zmd-mac-macos-arm64.pkg`，在系统安装器的「安装类型 → 自定」选择 **国服** 或 **Global · GRYPHLINK**，也可同时勾选。默认国服。

安装脚本直接获取官方启动器并生成 `~/Applications/终末地.app` 或 `~/Applications/终末地 Global.app`，创建桌面入口。无需再打开另一个安装器。双击生成的应用，由官方启动器下载游戏并开始游戏。

PKG 需要管理员授权，把共用安装资源放到 `/Library/Application Support/zmd-mac`；Wine 初始化及应用创建以当前桌面登录用户运行。两服各有独立运行环境、游戏目录和登录状态。已有同名应用时该项安装停止，不覆盖或升级游戏应用；重新安装时只选择尚未安装的服。

安装期间需要网络，每个所选服允许最多 30 分钟。Global 下载地址来自[Global 官网](https://endfield.gryphline.com/en-us/)，使用 GRYPHLINK；Global 完整游戏游玩尚未验证。

### ZIP（脚本／CLI）

解开 `zmd-mac-macos-arm64.zip`，保持 `zmd` 与 `payload` 同一目录。

双击 **`安装终末地.command`**，选择在线下载或通过文件选择器导入官方安装 EXE。也可以在解压目录打开终端：

```sh
./zmd doctor
./zmd install --desktop

# Global；默认生成独立的「终末地 Global.app」
./zmd install --region global --desktop

# 或导入已下载的终末地国服「官方启动器安装包」：
./zmd install --exe "/完整路径/HypergryphLauncher.exe" --desktop
# Global 本地 EXE 必须选对应的 GRYPHLINK 安装包
./zmd install --region global --exe "/完整路径/GRYPHLINK.exe" --desktop
```

默认生成 `~/Applications/终末地.app`，桌面入口是 Finder 替身。双击应用，在官方启动器下载游戏，再点击「开始游戏」。不能直接导入或启动 `Endfield.exe`。

已有同名应用时安装器会停止，保留原有内容。另建一份时：

```sh
./zmd install --output "$HOME/Applications/终末地测试.app"
```

未安装 Rosetta 时，按提示运行 `softwareupdate --install-rosetta` 并完成系统确认。当前产物为本地临时签名，没有 Developer ID 公证；从网络下载后可能需要在系统「隐私与安全性」允许打开该项目。不要关闭系统的全局安全检查。

## 配置与退出

新安装默认采用 **Vulkan + 窗口模式 + MSync**。游戏画质在游戏内设置；Vulkan 下曾报告 FSR 局部黑色网纹，TAAU 可避开。本机切到 DXMT 后，用户确认 DLSS / FSR 画面正常，但部分场景性能低于 Vulkan。

打开应用时默认同时显示原生 **运行设置** 窗口：

- **运行**：切换图形后端、Vulkan 稳定版／实验版、队列提交方式、窗口模式、MSync 和 Metal 性能面板。
- **调试**：选择 DXMT / Wine 日志级别，控制 DXMT 着色器缓存、Metal API / 着色器校验，打开日志文件夹。
- 取消「打开启动器时显示设置」后，下次不再自动弹出；仍可在启动器或游戏的左上角应用菜单选「终末地设置…」，或按 **⌘,** 打开。

自动显示开关立即保存；其余选项点「保存设置」，正常退出整个游戏会话后重开生效。关闭设置窗口不退出游戏。调试校验默认关闭，仅排障时开启。

```sh
# 显示环境版本与配置，不导出账号、注册表或启动日志
./zmd inspect --app "$HOME/Applications/终末地.app"

# Metal 性能面板
./zmd configure --app "$HOME/Applications/终末地.app" --hud on

# 不再自动弹出设置窗口（菜单入口保留）
./zmd configure --app "$HOME/Applications/终末地.app" --settings-window off

# 备用 DXMT 路径
./zmd configure --app "$HOME/Applications/终末地.app" --renderer dxmt

# 试用带 NGX 修复的 DXMT / MetalFX；进游戏选择 DLSS 质量，先关闭帧生成
./zmd configure --app "$HOME/Applications/终末地.app" --renderer dxmt-metalfx

# 恢复 Vulkan，窗口模式交给游戏自己控制
./zmd configure --app "$HOME/Applications/终末地.app" --renderer vulkan --window game

# Vulkan 后台队列实验：只改变提交方式，不是异步着色器编译
./zmd configure --app "$HOME/Applications/终末地.app" --renderer vulkan --vulkan-queue async

# 恢复稳定版 MoltenVK 与默认队列
./zmd configure --app "$HOME/Applications/终末地.app" --renderer vulkan --moltenvk stable --vulkan-queue default
```

配置在下次启动生效：正常退出游戏和启动器，再打开应用。`--hud off` 关闭面板；`--msync off|on` 用于同场景对照。更多方法见 [调优](docs/tuning.md)。

`dxmt-metalfx` 使用 DXMT 0.80 加上上游 [NGX 修复 #235](https://github.com/3Shain/dxmt/pull/235)，
并补齐本地 NVAPI 显卡识别接口，通过游戏的 DLSS 选项调用 MetalFX Temporal。
启动时从已下载的游戏复制签名 DLL 到独立 prefix，供 NGX 发现模块；实际执行 DXMT 的
内置实现。MetalFX 模式会禁用不支持的 DLSS 帧生成、光线重建和 DeepDVC 插件。
它保存在独立目录；`vulkan` 和原版 `dxmt` 均可切回，重启时自动还原 prefix 入口。
这不是 FSR 或帧生成修复，也不保证比 Vulkan 更快。

MoltenVK 实验版为可选组件，默认发行构建只包含稳定版。维护者可按[构建说明](docs/building.md#可选-moltenvk-实验版)
编译并打包实验库；安装了实验库的应用可在设置里切换，或使用 `--moltenvk experimental`。
实验库与稳定库分别保存，不需要复制游戏。当前实验版已通过基础渲染检查，终末地内的 FSR、插帧和性能仍待验证。
建议先比较版本，再单独比较队列方式；每次改动后正常退出游戏与启动器并重开。

包装入口在后台运行，Dock 只保留实际窗口的「鹰角启动器」和「终末地」图标。
在任一图标上选择「退出」，会先让游戏按正常关窗流程退出，再结束启动器会话。
不显示额外图标、退出角标或选择框；游戏取消退出或没有响应时，不会因超时强行结束。

游戏、更新缓存和登录状态存放在应用内部 `Contents/SharedSupport/prefix`。升级本项目时不要覆盖这份应用；退出后可整体移动或备份。仅删除桌面替身不会删除游戏。

## 自动构建与 Release

上传本项目源码到 GitHub 后：

- push 到 `main`／`master` 或在分支上手动运行 `Build`：从锁定来源构建 Wine，编译原生 CLI 和 .app 入口，上传构建 artifact。
- 推送版本标签（如 `v0.5.0`）：构建、包校验及源码归档全部成功后，自动发布 GitHub Release。
- 标签带后缀（如 `v0.5.0-rc.1`）：自动发布为预发布版，不替换 Latest。
- pull request：运行轻量检查，避免每次都重编 Wine。
- 构建使用 `xcode-27` Apple Silicon runner；发布 job 使用 GitHub 自带令牌，无需配置额外 Token。流程不会自动创建标签或提交源码。

维护者发布已确认的版本时：

```sh
git tag -a v0.5.0 -m "Release v0.5.0"
git push origin v0.5.0
```

标签数字版本须与打包的应用版本一致。发布附件包括 PKG、CLI ZIP、项目源码 ZIP、第三方源码 tar.gz
及各自校验文件。附件先上传到草稿，齐全后再公开；中断可重跑同一提交，不覆盖已公开版本。

开发机已有 macOS 27、Command Line Tools、Rosetta 2、Python 3 和 Git 时：

```sh
bash scripts/test.sh
bash scripts/build-release.sh
```

依赖解包到 `.work/`，不会运行 `brew install` 或安装 MacPorts。产物在 `release/`，不会覆盖既有文件。构建流程见 [构建说明](docs/building.md)。

## 配置与已知问题

- [运行环境与验证范围](docs/configuration.md)
- [性能调优与 FSR 黑纹](docs/tuning.md)
- [排障](docs/troubleshooting.md)
- [本地验证记录](docs/verification.md)
- [第三方组件](THIRD_PARTY_NOTICES.md)

本项目自有安装器和包装脚本采用 MIT；Wine 和第三方库分别遵循其原许可证。
