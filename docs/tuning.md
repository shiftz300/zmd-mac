# 性能调优

先固定场景、视角、分辨率、渲染比例与画质，关闭帧生成，用 TAAU 作基线。
进入场景等待首次着色器编译结束，再对同一段路线采样 60 秒。每次只改一项。
记录输出分辨率和内部渲染比例；“4K 输出”不自动等于原生 4K 渲染。

```sh
./zmd configure --app "$HOME/Applications/鹰角启动器.app" --hud on
```

退出游戏和启动器后重开。该开关启用 Apple 的
[Metal Performance HUD](https://developer.apple.com/documentation/xcode/customizing-metal-performance-hud)，
方便观察帧率、帧时间、GPU 时间及可用的内存指标。完成后用 `--hud off` 关闭。

| 现象 | 对照方法 | 下一步 |
| --- | --- | --- |
| 已稳定锁 60 FPS | 保持 60 FPS，比较 GPU 时间和功耗 | 优化可能只是增加余量，不会显示超过帧率上限 |
| 降低分辨率后明显更快 | 同场景从 4K 降到 1440p，其他项不变 | 优先调渲染比例、阴影、体积效果、反射 |
| 降分辨率基本没改善 | 对照 CPU/GPU 时间、帧率上限和 VSync | 再比较 MSync 与图形后端；不能仅凭 GPU 占用认定 CPU 瓶颈 |
| 首次进入新场景卡顿，第二遍缓解 | 重复同一路线 | 保留着色器缓存，不把清缓存当日常优化 |
| 时间越久越慢 | 观察内存压力、温度和后台负载 | 减少纹理占用或后台程序，再复测 |
| FSR 有黑色网纹 | 同一镜头切换 FSR 与 TAAU，帧生成关闭 | 当前优先用 TAAU；先解决画面正确性 |

## KosmicKrisp 缓存诊断

KosmicKrisp 启用原生 Vulkan 缓存层，将应用管线缓存压为带校验的 zstd 数据；
保留 Vulkan 公共头，读取时还原原始数据。使用运行库已有的 zstd，等级 1，
大缓存使用 4 个压缩线程，小缓存使用单线程。仅支持当前格式，不保留开发期间的旧格式兼容。
这避免了实测超过 4 GiB 的原始数据触发游戏缓存长度及文件写入限制。
缓存层不改着色器或绘制调用；同一缓存的重复长度／数据查询复用压缩快照，
创建管线或合并缓存后重新生成。切换到其他后端时不启用此层。

开发环境可运行：

```sh
swift run zmd-dev test-kosmickrisp-cache --app "$HOME/Applications/鹰角启动器.app"
swift run zmd-dev test-cache-codec --large
```

需要已构建的运行库、MinGW 和 Wine 头文件，与 `test-kosmickrisp` 的依赖相同。
`--runtime DIR` 可指定运行库；省略 `--app` 时只运行驱动测试。
结果保存在命令打印的 `build/kosmickrisp-cache/run-*/report.json`，每次使用新目录。

测试在临时 prefix 中创建并执行一个无资源的计算管线，依次启动四个独立 Wine 会话：
空应用缓存、读取已保存缓存、再次读取、再次使用空应用缓存。记录 Vulkan 的缓存命中反馈、
序列化字节数、首条管线创建耗时，以及独立 Mesa 缓存目录是否生成文件。
每轮构建 64 条计算管线，覆盖超过 4 KB 的文件写入，并检查仅查询 32 字节头部时没有越界写入、
管线新增后的快照更新、重复读取一致性和损坏缓存回退。`--large` 单独验证超过 4 GiB 数据的无损往返及损坏输入拒绝。
这里的“空缓存”不清理系统 Metal 缓存；最后一轮用于避免把系统预热误算成应用管线缓存收益。
简单管线的耗时不能换算成游戏帧率或场景卡顿改善。

提供 `--app` 时，只读记录已知游戏缓存的大小、哈希和日志中的缺失／不兼容／读取失败提示。
游戏文件有私有封装，偏移 32 处的 Vulkan 头仅作为候选，与测试设备的 vendor、device、UUID 比较；
匹配不代表游戏已经成功加载整个缓存。工具不启动游戏、不改配置、不清理游戏或系统缓存。

当前锁定的 Mesa `b23137f730fa` 已实测支持应用传入的管线缓存跨进程命中。
其 KosmicKrisp 源码未创建独立 Mesa 磁盘缓存，本次独立缓存目录也没有生成文件；
不要把 `MESA_SHADER_CACHE_MAX_SIZE` 当作本版本已验证有效的优化。
切换 Vulkan 驱动后，旧的游戏 PSO 缓存可能因设备标识或 UUID 不同而被拒绝，这不等于新驱动的缓存机制失效。

真实游戏验证时固定后端、画质和分辨率，同一视角转动两遍，再正常退出并重进重复观察。
重进后仍卡顿可能涉及 Metal 最终编译、资源加载或游戏是否完整保存管线，不能只凭一次头匹配归因。

## FSR 黑纹

此前 Vulkan 路径的用户反馈为：各 FSR 模式均出现小区域黑色网纹，TAAU 下消失。这支持问题位于
FSR 相关渲染路径的判断，不能仅凭描述断定是游戏、MoltenVK、SPIRV-Cross 或 Metal 驱动哪一层。
用户另报告：开启帧生成时还会出现 UI 百叶窗状异常及间歇卡顿。超分辨率黑纹与帧生成
异常应分开对照；AMD 的 [FSR 集成文档](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-interpolation/)
说明帧生成需要单独处理 UI 合成、资源生命周期和呈现节奏，仅凭现象尚不能确定是哪一项出错。

[上游 Vulkan issue](https://github.com/stoicswe/Endfield_FineWine/issues/22)
曾记录类似时域渲染异常和着色器转换修复。当前已经使用带补丁的 MoltenVK 1.4.2；
“版本已更新”不代表这个新报告也已经解决。

进一步定位需要：同一场景的 FSR/TAAU 截图、输出分辨率与渲染比例、帧生成状态、
是否随镜头运动、`inspect` 输出。先关闭帧生成做对照；有条件时，在另一份测试应用
对比 DXMT 路径。若仅 Vulkan 出错，再研究 MoltenVK/SPIRV-Cross 的具体修复。
不要同时换 Wine、图形库、画质和缓存，否则无法判断是哪一项造成差异。

2026-10-21 核对：现有动态库 SHA-256 与 FineWine 1.2.4 发布包一致，上游
MoltenVK 最新正式版仍是 1.4.2；当前补丁已含顶点位置不变性修复，用于解决深度预通道
与后续 EQUAL 深度测试不一致造成的时域拖影。未找到针对本次黑纹／UI 百叶窗的新增成品修复。
首次对照可直接使用包内 DXMT 0.80：同场景、同分辨率，关闭帧生成，只切换 FSR/TAAU。
Vulkan 出错而 DXMT 正常，才支持继续聚焦 Vulkan/MoltenVK 路径。

另一条可选超分路线是 **DXMT + MetalFX Temporal**。
[DXMT #235](https://github.com/3Shain/dxmt/pull/235) 于 2026-10-16 合并，
修复终末地传入 NGX 纹理参数时 `void *` 与 D3D 资源指针转换失败导致的 DLSS 黑屏。
上游给出了 M5 Pro 上的前后对照。本机用户随后确认 DLSS / FSR 画面正常；性能主观反馈低于此前 Vulkan，首次转向复杂场景时卡顿、重复转向后改善，尚无同场景帧时间测量。
本包提供独立的 `dxmt-metalfx` 后端：以 DXMT 0.80 为基础，重编带此补丁的 x64
`nvngx.dll`，并为 `nvapi64.dll` 补齐 `NvAPI_GetLogicalGPUFromPhysicalGPU`。
缺少后者时，本机游戏的 Streamline 2.10.3 会提前结束显卡检测，隐藏 DLSS 选项。
其余 DXMT 渲染模块保留。选择它会启用 NVEXT，并通过官方启动器给游戏追加
`-force-d3d11`。游戏里选择 **DLSS → 质量**，先关闭帧生成；此时调用的是 DXMT 自身
的 **MetalFX Temporal**，无需 GPTK，也不代表支持 DLSS 帧生成。
原版 `dxmt` 不启用 NVEXT；`vulkan` 路径与原版 DXMT 文件均保留。

独立 Wine 还需要处理 NGX 的签名入口，具体依据
[DXMT Vendor Extensions](https://github.com/3Shain/dxmt/wiki/Vendor-Extensions)：
本项目只在自己的 prefix 内准备签名文件，并指定 `nvngx=b` 加载 DXMT 实现。
同时禁用 `sl.dlss_g`、`sl.dlss_d`、`sl.deepdvc`，避免不支持的插件尝试初始化
D3D12 路径。隔离测试已通过游戏自带 Streamline 的 DLSS 检测、D3D11 设备初始化
和 4K「质量」参数查询；这些结果不代替真实游戏画面验证。

FSR 超分辨率和帧生成是不同功能。Native AA 也可能不降低内部渲染分辨率。
已经锁 60 FPS 时，开启 FSR 后帧率不变并不说明它没工作；应比较 GPU 时间、
画质及输入延迟。帧生成增加显示帧数，也会带来额外开销，不能当作游戏逻辑帧率。

## 可逆的后端与同步测试

```sh
./zmd configure --app "$HOME/Applications/鹰角启动器.app" --renderer dxmt --window windowed
./zmd configure --app "$HOME/Applications/鹰角启动器.app" --renderer dxmt-metalfx --window windowed
./zmd configure --app "$HOME/Applications/鹰角启动器.app" --renderer vulkan --window windowed
./zmd configure --app "$HOME/Applications/鹰角启动器.app" --msync off
./zmd configure --app "$HOME/Applications/鹰角启动器.app" --msync on
```

每次设置后正常退出并重开。不清理缓存、不修改游戏可执行文件，也不自动降低画质。
后端的名称不能决定性能，必须以同机同场景结果为准。
MetalFX 出现异常时先在游戏内恢复 TAAU，正常退出后切回 `vulkan`；
若游戏无法进入，可直接用 CLI 切回 Vulkan 再启动。所有切换均不删除着色器缓存。

## 原生调试选项

在「运行设置 → 调试」中修改，或使用 `./zmd configure --app "/应用路径/鹰角启动器.app"` 加下表参数。保存后退出游戏及启动器并重开，运行中的会话不会被修改。

| CLI 参数 | 默认 | 对应行为 |
| --- | --- | --- |
| `--dxmt-log default\|error\|debug\|none` | `default` | 默认使用 DXMT 自身日志策略；其他档位设置 `DXMT_LOG_LEVEL` |
| `--wine-log errors\|warnings\|off` | `errors` | `WINEDEBUG` 仅错误／错误及警告／关闭 |
| `--shader-cache on\|off` | `on` | `DXMT_SHADER_CACHE=1/0`，仅影响 DXMT，不删除已有缓存 |
| `--metal-validation on\|off` | `off` | `MTL_DEBUG_LAYER=1/0`，Metal API 校验 |
| `--shader-validation on\|off` | `off` | `MTL_SHADER_VALIDATION=1/0`，Metal 着色器校验 |

Metal 校验会增加开销，不作为性能优化开关。排障后关闭校验，并把 DXMT 日志恢复为 `default`、Wine 日志恢复为 `errors`。已有自定义环境变量在对应配置文件未创建时仍可生效；保存明确选项后以应用配置为准。

「打开日志文件夹」定位这份应用自己的 `Contents/SharedSupport/logs`。分享前检查日志内容；可能包含本机路径及启动器诊断信息。
