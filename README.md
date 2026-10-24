# zmd-mac

在 Mac 上运行《明日方舟：终末地》，支持国服和 Global。目标系统 **macOS 14+**；旧系统及 Intel Mac 尚未实测。

1. 从 [Releases](https://github.com/shiftz300/zmd-mac/releases/latest) 下载 **PKG**：Apple Silicon 选 **arm64**（需要 Rosetta 2），Intel 选 **x86_64**（无需 Rosetta）。双击安装，在「安装类型 → 自定」选择国服或 Global。
2. 从启动台打开「鹰角启动器」或「GRYPHLINK」，登录并下载游戏。
3. 在官方启动器中点击「开始游戏」。

Apple Silicon + macOS 26+ 默认使用 **KosmicKrisp**，其余默认使用 **MoltenVK**。在左上角应用菜单选择「运行设置…」（**⌘,**）可切换可用后端；保存后选择重启启动器，再启动游戏。

也可下载 **ZIP**，解压后双击 `安装终末地.command`，按提示下载官方启动器或选择本地安装 EXE。
如被系统拦截，请在「系统设置 → 隐私与安全性」中允许打开。

[详细设置](docs/configuration.md) · [排障](docs/troubleshooting.md) · [构建](docs/building.md) · [第三方许可](THIRD_PARTY_NOTICES.md)

非官方项目，不包含游戏文件。Global 完整游玩尚未验证。游戏和登录状态保存在应用内部，升级时请勿直接覆盖已有应用。
