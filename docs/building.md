# 构建与发布

开发需要 Apple Silicon、macOS 27、Rosetta 2、Command Line Tools（Swift、Clang）和 Git。
项目的安装、启动、构建、测试和发布工具使用 Swift，不需要 Python、Homebrew 或额外 Swift 包。
PKG 保留三份简短 Shell 钩子，负责安装前检查和切换登录用户；ZIP 的双击入口也保留为短 Shell。Wine 上游仍使用自己的 configure／Makefile。

```sh
swift run zmd-dev test
ZMD_WORK_DIR="$PWD/.work" swift run zmd-dev build
```

`build` 下载锁定依赖，编译 Wine 和 MetalFX，生成 CLI ZIP 与 PKG。输出到 `release/`；已有产物拒绝覆盖。
`ZMD_WORK_DIR` 默认是项目目录，CI 使用 `.work`。`ZMD_RELEASE_OUTPUT` 可指定另一输出目录。
版本号集中在 `Sources/Development/Support.swift`。

已有独立运行库可复用：

```sh
ZMD_RUNTIME_SOURCE="$PWD/runtime" \
ZMD_SEVENZIP_SOURCE="$PWD/tools/native/opt/sevenzip" \
swift run zmd-dev build
```

这只重建安装器与包装层，不代表全新环境中的 Wine 完整构建已经验证。

## 代码结构

- `Sources/zmd/`：Swift CLI、配置校验、Wine 环境和 MetalFX 文件恢复。
- `Sources/Launcher/`：原生 AppKit 入口、运行设置和会话退出。
- `Sources/Development/`：依赖准备、构建、打包、发布与测试编排。
- `Tests/`：Swift 回归用例及 Win32／图形测试程序。
- `Resources/`：初始注册表、PKG Shell 钩子和 ZIP 双击入口。
- `Patches/`：Wine、DXMT 补丁。

`swift run zmd-dev --help` 查看全部命令。运行逻辑编译进原生可执行文件，应用内不再串联 Shell。
配置仍兼容旧包装层；不支持的新选项会在写入前拒绝。

## 桌面集成测试

```sh
swift run zmd-dev test-lifecycle
swift run zmd-dev test-session
swift run zmd-dev test-display
```

这些测试需要已登录的 macOS 桌面。只启动隔离测试程序，不加载已安装游戏。
前两项验证退出、延迟、取消后重试、重启、缓存清理和不同 prefix 隔离。
后两项需要本地 MinGW 工具及已构建 Wine。
显示测试检查非空显示器句柄和隐藏窗口跨屏映射，不代替游戏内全屏验收。

`wine` 命令在 FineWine 补丁之后应用 `wine-session-dock.patch` 和 `wine-display-monitors.patch`。
补丁及 Wine 模块（含 `win32u.so`）哈希保存在运行库 provenance 中，打包会验证这些记录。

仅更新已有应用的原生入口（先退出整个游戏会话）：

```sh
swift run zmd-dev update-app --app "$HOME/Applications/鹰角启动器.app"
```

旧入口会备份到工作目录，不复制游戏或修改登录状态。

## 图形后端

默认构建包含稳定版 MoltenVK 和独立 DXMT + MetalFX。
MetalFX 基于锁定的 DXMT 0.80，回移 NGX #235 并补充 NVAPI 逻辑 GPU 查询。
源码、补丁和编译器输入均有锁定哈希，不链接 NVIDIA 驱动库，不打包游戏签名 DLL。

```sh
swift run zmd-dev metalfx --runtime "$PWD/runtime"
swift run zmd-dev experimental --runtime "$PWD/runtime" --jobs 6
swift run zmd-dev test-vulkan --runtime "$PWD/runtime"
```

实验版另需 CMake 和 Ninja。固定来源见 `moltenvk-experimental.lock.json`：
MoltenVK `5189f8de86ec`、SPIRV-Cross `aa217aeb6c9f`，保留 FineWine 的图形补丁。
构建 x86_64 Release 库、静态链接外部依赖、保留管线缓存，省略调试用 SPIRV-Tools。
源码归档构建显式设置 MoltenVK revision，避免使用外层仓库提交生成缓存 UUID。

实验版只写 `renderers/moltenvk-experimental`，不覆盖稳定版，也不自动启用。
目标已存在时拒绝重建；先保留旧目录。完整发行构建默认不编译实验版，复用已有运行库时会携带它。
`test-vulkan` 验证两个版本和两种队列模式下的设备、窗口、清屏及呈现，不验证游戏、FSR 或性能。

## PKG 与安装检查

```sh
swift run zmd-dev pkg --distribution release/zmd-mac --output release/zmd-mac-macos-arm64.pkg
swift run zmd-dev test-pkg --package release/zmd-mac-macos-arm64.pkg
```

PKG 由系统 `pkgbuild` / `productbuild` 生成，可选择国服、Global 或两服。
共用只读资源安装到 `/Library/Application Support/zmd-mac`。
Shell 钩子读取当前控制台登录用户，通过 `launchctl asuser` / `sudo -u` 清理环境后调用 Swift CLI。
不会以 root 启动 Wine，不另做安装器应用。没有登录用户、非启动磁盘或缺少 Rosetta 时停止。
组件安装超时为 1800 秒，已有用户应用由 CLI 的拒绝覆盖逻辑保护。

`test-pkg` 只检查内容及安装选项，不执行系统安装。
使用真实官方 EXE 验证两服安装、图标和注册：

```sh
swift run zmd-dev test-install --distribution release/zmd-mac \
  --cn-exe /路径/HypergryphLauncher.exe --global-exe /路径/GRYPHLINK.exe
```

它在临时目录安装并注销测试入口，不启动游戏。

## 自动发布

CI 在 main/master 推送时构建，PR 运行快速检查。构建和发布均使用 `xcode-27` runner。
推送与集中版本号一致的 `vX.Y.Z` 标签会发布 GitHub Release；`-rc.1` 等后缀生成预发布版。
分支构建只上传 Actions artifact，不自动创建标签。

```sh
ZMD_WORK_DIR="$PWD/.work" swift run zmd-dev sources
swift run zmd-dev release --tag v0.6.2 --directory release --check-only
```

源码包包含锁定的上游源码、补丁、许可证及 Swift 构建资料；含实验运行库时也加入对应实验源码。
发布附件为 PKG、CLI ZIP 和第三方源码 tar.gz。项目源码使用 GitHub 自带入口；校验文件只供 CI 使用。
发布前核验附件、SHA-256 和版本，先上传草稿，确认附件齐全后公开。
失败时保留草稿，可从同一提交续传；不会覆盖公开 Release 或其他提交的草稿。
只有发布 job 有 `contents: write`，使用 `GITHUB_TOKEN`，不需要额外个人令牌。

第三方二进制按各自许可证提供对应源码和构建资料，不要上传个人已安装应用。
目前仅临时签名，尚未 Developer ID 公证。
