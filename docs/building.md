# 构建与发布

使用者运行系统 PKG 安装器或预构建 Swift CLI。开发／CI 需要 Apple Silicon、macOS 27、Rosetta 2、
Command Line Tools（含 Swift、Clang）、Git、Python 3。构建脚本从锁定来源下载工具，
解包到项目工作目录；Python 不进入消费包。

```sh
bash scripts/test.sh
bash scripts/build-release.sh
```

退出流程的桌面集成测试单独运行：

```sh
python3 scripts/test-native-launcher.py
python3 scripts/test-wine-session.py
```

该测试需要已登录的 macOS 桌面会话，只启动隐藏的隔离测试程序，
验证正常退出、延迟、取消后重试、退出顺序和不同 Wine prefix 的隔离。
第二项使用补丁后的 Wine 和隐藏 Win32 窗口，验证从游戏／启动器任一图标发起退出、
中文应用名，以及拒绝会话结束但接受正常关窗的游戏。需要本地 MinGW 构建工具。
测试创建全新 prefix，不加载用户安装的游戏。

`build-wine.sh` 在 FineWine 补丁之后运行 `prepare-session-patch.py`，应用本地
`wine-session-dock.patch`。该补丁和哈希记录在运行库 provenance 的 `wine.local_patches`；
相关 Wine 模块哈希记录在 `session_modules`。后台入口必须与该补丁一起升级，
打包脚本会拒绝缺少匹配补丁的旧运行库。

默认工作目录为 `.work`，输出为 `release/zmd-mac` 和
`release/zmd-mac-macos-arm64.zip`、`release/zmd-mac-macos-arm64.pkg`。默认下载依赖、应用补丁、编译 Wine、
打包运行库，再构建 Swift CLI 与原生 AppKit 入口。输出已存在时拒绝覆盖；
保留或移走旧产物后再构建。

构建还会用已有 MinGW 和 Wine `winebuild` 编译独立的 `dxmt-metalfx` 后端：
固定 DXMT 0.80 源码 SHA-256，回移上游 #235 并重编 x64 `nvngx.dll`；
另加本地逻辑 GPU 查询补丁，使用同版本 DXMT 的锁定 NVAPI 头文件重编 `nvapi64.dll`。
不链接 NVIDIA 驱动库，不打包游戏自带的签名 DLL。
无需完整 Xcode、Meson 或新的用户端依赖。补丁位于 `scripts/patches/`；
源码包、补丁、许可证和构建脚本随源码资料保留。
已有开发运行库需要先执行 `python3 scripts/build-dxmt-metalfx.py`。
若已有不同版本的 `runtime/renderers/dxmt-metalfx`，先将其移至备份目录；脚本拒绝覆盖。

## 可选 MoltenVK 实验版

```sh
python3 scripts/build-moltenvk-experimental.py --runtime "$PWD/runtime"
python3 scripts/test-vulkan.py --runtime "$PWD/runtime"
```

另外需要开发机上的 CMake 和 Ninja；使用 Command Line Tools 的 Clang，不需要完整 Xcode。
固定来源见 `moltenvk-experimental.lock.json`：MoltenVK `5189f8de86ec`（1.4.3 开发版），
配套 SPIRV-Cross `aa217aeb6c9f`；保留 FineWine 的 7 个 MoltenVK 补丁和 1 个 SPIRV-Cross 补丁。
Release 构建仅生成 Rosetta Wine 使用的 x86_64 库，外部依赖静态链接，最终只依赖 macOS 系统库。
保留管线缓存支持；省略只用于调试反汇编的 SPIRV-Tools。
源码归档构建显式记录正确的 MoltenVK revision，避免误用外层 zmd-mac Git 提交生成缓存 UUID。

脚本只写入 `renderers/moltenvk-experimental`，不改稳定版或自动启用实验版，目标已存在时拒绝覆盖。
需要更新时先保留旧实验目录再构建；日常只维护一个稳定槽和一个实验槽。
默认完整发行构建不编译此选装项；打包已有运行库时会携带其中的实验库与许可证。
使用 `package-sources.py` 时，其工作目录中的运行库若包含实验库，也会加入锁定的实验源码。

`test-vulkan.py` 使用临时 prefix，检查两个版本 × 两种队列模式的窗口、设备、清屏、呈现和退出。
需要已登录的图形桌面；它不验证终末地着色器、FSR、插帧或游戏性能。
游戏对照顺序：稳定＋默认 → 实验＋默认 → 实验＋后台队列；保持场景、画质与超分档位一致。
每次切换都完整重启会话，新版本首次访问场景可能重新建立缓存，不与热缓存数据混比。

复用开发机上已有的独立运行库：

```sh
ZMD_RUNTIME_SOURCE="$PWD/runtime" \
ZMD_SEVENZIP_SOURCE="$PWD/tools/native/opt/sevenzip" \
bash scripts/build-release.sh
```

这只重建安装器与包装层，不证明完整 Wine 在新环境中可重建。
`ZMD_WORK_DIR` 可指定构建工作目录，`ZMD_RELEASE_OUTPUT` 可指定另一个输出目录。

PKG 通过系统 `pkgbuild` / `productbuild` 构建，包含共用只读安装资源与两服的组件脚本。
不生成额外安装器应用，也不从 root 启动 Wine。`pkg-user.sh` 识别当前控制台登录用户，
通过 `launchctl asuser` / `sudo -u` 切换用户并清理继承环境，随后运行同一 Swift 安装流程。
两服的非可执行 receipt bundle 用于配置组件脚本 1800 秒超时；不包含游戏。
没有登录用户、非启动磁盘、未安装 Rosetta 时停止。原有应用由 CLI 的拒绝覆盖检查保护。
仅重建 PKG 和检查内容：

```sh
python3 scripts/package-pkg.py --distribution release/zmd-mac --output release/zmd-mac-macos-arm64.pkg
python3 scripts/test-pkg.py release/zmd-mac-macos-arm64.pkg
```

PKG 内容和选择项检查不会执行系统安装；全新用户的系统安装验收需另行执行。

GitHub `Build` 工作流在 main/master push、v* 标签和手动触发时执行完整构建。
`Checks` 在 pull request 执行快速测试。当前使用
[xcode-27 Apple Silicon runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)，
该标签的可用性和镜像变化由 GitHub 决定。本地构建成功不等于远端 Actions 已成功。

## 源码与二进制

```sh
python3 scripts/export-source.py
```

该脚本按白名单导出项目源码 ZIP，排除下载缓存、游戏、prefix、运行库、日志和账号状态。
导出目录可直接作为新的 GitHub 仓库内容，之后由维护者自行审核、提交与推送。

二进制产物包含第三方开源组件，分别保留原许可证与来源。
Wine 的固定源码、补丁系列、依赖锁与构建脚本共同构成重建资料。
`python3 scripts/package-sources.py` 会保留锁定的上游源码包、组件许可证和构建资料；
CI 将其作为 `third-party-source-inputs` artifact 上传。该脚本与完整构建使用相同
`ZMD_WORK_DIR`。
发布修改后的第三方二进制时，应一同提供适用许可证要求的对应源码与构建资料，
不要只上传个人已安装应用。参见 [第三方组件](../THIRD_PARTY_NOTICES.md)。

当前只使用临时签名，没有 Developer ID 公证。需要公证时应另行配置维护者证书与签名流程。

## 自动 GitHub Release

推送 `v主版本.次版本.修订号` 标签后，`Build` 会自动完成构建和校验，再发布 GitHub Release。
例如 `v0.5.2` 为正式版，`v0.5.2-rc.1` 为预发布版；预发布版不会标记为 Latest。
标签的数字版本必须与安装包中的应用版本一致。更新版本时同步修改
`package-distribution.py`、`package-pkg.py`、`install-native-launcher.py` 的版本字段。

```sh
git tag -a v0.5.2 -m "Release v0.5.2"
git push origin v0.5.2
```

发布附件为 PKG、CLI ZIP 和第三方源码 tar.gz。项目源码使用 GitHub 自带的下载入口；
SHA-256 文件仅供 CI 发布前校验，不上传到 Release。第三方源码包包含上游依赖及构建资料，
不属于 GitHub 自动生成的项目源码包，仍随二进制提供。
独立发布 job 在构建及源码归档成功后才运行，只给该 job `contents: write`，使用自带的
`GITHUB_TOKEN`，不需要额外配置个人访问令牌。先建立草稿，上传并确认三个附件齐全后公开。
上传失败会保留草稿；重跑同一提交可续传。不会覆盖已公开的 Release，也不会接管其他提交的草稿。
普通分支推送和分支上的手动构建只上传 Actions artifact；手动选择版本标签运行时也会发布。
此流程不会自动创建或推送版本标签。

本地验证发布附件（不会连接 GitHub）：

```sh
python3 scripts/publish-release.py --tag v0.5.2 --directory release --check-only
python3 scripts/test-release.py
```
