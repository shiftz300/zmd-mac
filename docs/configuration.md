# 运行环境

| 项目 | 配置 |
| --- | --- |
| Wine | wine-11.0，基于 CodeWeavers 26.3.0 公开源码 |
| 补丁 | FineWine `a62d906c18e790acad3603ea639a3baba4e201ad`，按固定顺序应用 70 个补丁 |
| 本地桌面集成 | 另加 `wine-session-dock.patch`，为当前包装会话提供中文进程名和 Dock 退出转发 |
| CPU | x86_64 Wine 经 Rosetta 2，支持 i386 / x86_64 Windows 程序 |
| 同步 | 默认 `WINEMSYNC=1`，`ROSETTA_ADVERTISE_AVX=1` |
| 默认游戏路径 | 游戏 Vulkan → 修补版 MoltenVK 1.4.2 → Metal |
| 备用路径 | 游戏 Direct3D 11 → DXMT 0.80 → Metal |
| MetalFX 试用路径 | `dxmt-metalfx`：DXMT 0.80 + 上游 #235 NGX 修复 + 本地 NVAPI 识别补丁，`DXMT_ENABLE_NVEXT=1`；游戏内选 DLSS |
| 官方启动器 | DXMT 支持其 Direct3D 界面；由 `Launcher.exe` 调用版本目录内的 `Games.exe` |
| 游戏参数 | 只对 `Endfield.exe` 追加 `-force-vulkan` 或 `-force-d3d11` |
| 窗口模式 | 默认追加 `-screen-fullscreen 0`，游戏设置可能覆盖它 |
| 字体 | 使用 macOS 自带 Heiti SC，不分发字体 |
| DLL 设置 | `winemenubuilder.exe=d;mscoree,mshtml=` |

Vulkan 通过 `CX_LIBVULKAN` 指向应用内 MoltenVK。该 Wine 分支需要
`CX_ACTIVE_GRAPHICS_BACKEND=wined3d` 才使用这个库，名称不表示游戏在使用 OpenGL。
两种图形路径都不依赖 D3DMetal 或 GPTK。
`WINEDLLPATH` 明确指向应用自身的 Wine 模块目录，以启用本构建的具名加载器。
后台入口为每次会话生成 `ZMD_SESSION_ID`；只接受该会话且进程身份、prefix 均匹配的退出请求。
进程命名和退出桥接仅对带此会话标识的 Wine 程序生效。包装层设置 `LSUIElement`，
自身不出现在 Dock，官方启动器和游戏继续使用各自窗口提供的图标。
退出请求依次交给游戏和官方启动器；Qt / Chromium 辅助进程由启动器自行收尾，
包装层不再向这些辅助进程单独发送退出通知，避免打断启动器的关闭过程。
国服启动器 1.6.0 的 `Games.exe` 通过其已加载的 Qt 5 x64 模块，将自身
`OnTrayReqExitApp` 动作排入界面线程，等同于启动器托盘里的「退出应用」。
不再向它发送 Windows 会话结束通知；找不到 Qt 接口或该动作时保留会话，
记录日志并允许重试。此适配不分发 Qt 或启动器 DLL，启动器更新后需要重新验证。

MoltenVK 来自 FineWine 1.2.4 模块发布包，来源及哈希写入
`runtime/renderers/moltenvk/provenance.json`。Wine、补丁和 DXMT 的记录在
`runtime/provenance.json`。CLI 的 `inspect` 可读取这些公开信息。
独立 MetalFX 后端的补丁和 DLL 哈希位于 `runtime/renderers/dxmt-metalfx/provenance.json`。

原生设置的「Vulkan 版本」提供稳定版／实验版；「队列提交」提供默认（同步）／后台队列。
也可使用 `zmd configure --app 应用.app --renderer vulkan --moltenvk experimental --vulkan-queue default`。
实验版单独安装到 `runtime/renderers/moltenvk-experimental`，未安装时拒绝保存该选项。
未设置时始终使用稳定版和同步提交；实验库缺失时会报错，不静默换库。
后台队列对应 `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0`，默认对应 `1`，
仅在 Vulkan 路径生效。它改变命令提交线程，不是异步着色器编译。
保存只影响下一次完整会话；退出游戏和官方启动器后再重开。
恢复时选择稳定版与默认队列，或 `--moltenvk stable --vulkan-queue default`。
实验库、源码提交与 SHA-256 可通过 `zmd inspect` 查看。

切回 `vulkan` 或原版 `dxmt` 时会关闭 NVEXT。
MetalFX 模式另加 `nvngx=b;sl.dlss_g,sl.dlss_d,sl.deepdvc=d`，只启用支持的
DLSS 超分接口。`prepare-metalfx.sh` 从本机游戏复制签名 `nvngx_dlss.dll` 到
prefix 的 `windows/system32/nvngx.dll`，由 NGX SDK 检查磁盘入口；Wine 实际加载
独立后端的 builtin NGX。该游戏 DLL 不随发行包分发，游戏目录保持原样。
原入口备份于 prefix 的 `.zmd-metalfx-ngx`；切回其他后端并重启时还原。
检测到其他工具改写入口时会停止并保留备份，避免覆盖其修改。
首次下载游戏时若已选择 MetalFX，需要退出整个会话再重开，以准备入口。

## 验证范围

自定义启动分辨率同时写入 Unity 启动参数和终末地已有的 `Screenmanager Resolution`
及 `video_resolution_width/height` 宽高配置，防止游戏加载旧值覆盖参数。
仅在新会话、官方启动器打开前写入；首次运行尚未生成游戏配置时只应用启动参数。
原值保存在 `Contents/SharedSupport/display-resolution-original.reg`，只包含分辨率项。
选择「使用游戏设置」后不再覆盖这些项，但不会自动还原之前的尺寸。
这不会扩充游戏自身的下拉菜单，也不保证游戏接受任意自定义尺寸。
实现依据本机注册表及 [Endfield Resolution Editor 的配置项说明](https://github.com/InfSein/endfield-resolution-editor#registry-keys-updated)。
真实 Wine 的隔离写入测试可运行 `swift run zmd-dev test-resolution`。

2026-10-20 的本机环境为 M5 Pro、24 GB、macOS 27.0.1。此前已完成
32/64 位 Windows 执行、官方 HTTPS、DXMT 设备创建、Vulkan 窗口和交换链检查。
用户确认从官方启动器进入国服，Vulkan 窗口正常。

用户反馈 4K 输出、60 FPS、全高，但没有固定场景帧时间记录，也没有确认当时
渲染比例、超分辨率及帧生成状态。这不是原生 4K 的独立性能基准。

2026-10-21 用户此前在 Vulkan 路径报告 FSR 有局部黑色网纹，切到 TAAU 后消失。
切换至修补版 DXMT 后，用户确认 DLSS 和 FSR 画面均正常，但流畅度不如此前的
MoltenVK；首次转向复杂场景时明显卡顿，重复转向后改善。尚无帧时间采样，
不能单凭这一现象区分着色器编译、资源加载或其他首次使用开销。
此反馈不表示 Vulkan 路径的 FSR 问题已修复。

进入游戏不等于长期稳定性或完整 ACE 流程已验证。后续游戏／启动器更新也可能改变兼容性。
2026-10-21 用户先确认只剩启动器和游戏两个图标，随后报告启动器的 Dock 退出
仍会留下不可恢复窗口的后台进程。日志确认退出请求已送达但超时，期间反复出现
辅助进程。已修正退出顺序；隔离回归测试覆盖辅助进程自行结束、取消及重试。
仅修正辅助进程顺序仍复现卡住；改为启动器自身托盘退出动作后，
本机真实 1.6.0 启动器、网页辅助进程与后台包装层均正常结束。
本次真实验证未启动游戏；游戏运行中的组合退出仍需后续人工确认。
