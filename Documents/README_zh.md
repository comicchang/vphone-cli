<div align="right"><a href="../README.md">English</a> · <strong>中文</strong> · <a href="README_ja.md">日本語</a> · <a href="README_ko.md">한국어</a></div>

# vphone-cli

在 Apple Silicon Mac 上运行虚拟 iPhone。

![在 macOS 上运行的虚拟 iPhone](demo.jpeg)

vphone-cli 使用 Apple 的 Virtualization.framework 和 PCC 研究虚拟机运行 iOS，适合安全研究、逆向和调试。

- **图形窗口**：在 Mac 上操作虚拟 iPhone 的屏幕，浏览 App 和文件，截图、录屏。
- **自定义固件（Custom Firmware）**：系统已预先打好补丁，可以安装软件包环境。
- **备份与克隆**：虚拟机可以导出、导入和克隆。
- **自动化 API**：可选的本机 HTTP 和 WebSocket 接口。
- **无需额外依赖**：运行时不需要 Xcode、Python 或 Homebrew。

> 1.x 版本请前往 [1.0.14 Release](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14)。2.x 无法启动 1.x 创建的虚拟机，需要重新创建。

## 准备工作

- 一台实体 Apple Silicon Mac，运行 macOS 15 或更新版本。macOS 虚拟机中无法使用。
- 足够的磁盘空间。每台虚拟机默认使用 64 GB 虚拟磁盘，固件和临时文件另外占用空间。
- 网络连接。恢复系统时需要在线获取签名票据。
- 修改安全设置。进入 macOS 恢复模式，在终端中执行以下命令，然后重新启动：

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP 仍保持开启，只放宽调试限制。原因和其他设置方式见[宿主机设置](Guides/host-setup.md)。

## 快速开始

1. 下载最新的 [vphone-launchpad](https://github.com/Lakr233/vphone-cli/releases/latest)（`vphone-launchpad-<版本>.zip`），解压并打开。
2. 在 **Host Setup** 中授予开发者工具权限，并安装辅助程序。
3. 在 **Core Bundle** 中点击 **Download and Install**。Launchpad 会下载并校验 `VPhone.bundle`，然后允许其中的虚拟机程序在本机运行。
4. 在 **Machines** 中点击 **New Machine**，选择一组固件，点击 **Create**。

Launchpad 会下载固件、打补丁、恢复系统并首次启动。完成后虚拟机会继续运行。

也可以使用自己的 iPhone 和 cloudOS IPSW，已验证的组合见[兼容性说明](Guides/compatibility.md)。

## 安装软件包环境

虚拟机默认不带软件包管理器。安装步骤：

1. 在菜单栏选择 **Apps > Install Bootstrap…**，布局选择 **roothide**（**rootless** 已弃用）。虚拟机中会安装 Irisin。
2. 首次安装时，在 Irisin 中勾选 `apt` 和 `bash`，长按安装按钮，选择 **Bootstrap Install**。`bash` 和 `debianutils` 互相依赖，普通安装无法完成。
3. 之后使用普通安装即可。

要删除环境，选择 **Apps > Uninstall Bootstrap…**，删除后虚拟机会重启。

按住 Option 打开 **Apps** 菜单，还有两个选项：

- **Install Bootstrap from File…**：使用本地的 Irisin `.deb` 安装。
- **Uninstall Bootstrap Without Restarting…**：删除环境，不重启虚拟机。

## 命令行

Launchpad 通过 `VPhone.bundle` 中的 `vphone-cli` 管理虚拟机，你也可以在终端中直接使用：

| 操作 | 命令 |
| --- | --- |
| 列出虚拟机 | `vphone-cli vm list` |
| 查看虚拟机信息 | `vphone-cli vm info myphone` |
| 启动虚拟机 | `vphone-cli vm launch myphone` |
| 停止虚拟机 | `vphone-cli vm stop myphone` |
| 克隆虚拟机 | `vphone-cli vm clone myphone copy` |
| 导出虚拟机 | `vphone-cli vm export myphone --out myphone.tzst` |
| 导入虚拟机 | `vphone-cli vm import myphone.tzst --name restored` |

虚拟机默认保存在 `~/.vphone/`。运行 `vphone-cli <group> --help` 查看全部命令。不使用 Launchpad 创建虚拟机的方法见[创建与运行](Guides/create-and-run.md)。

### 自动化 API

启动时加上 `--api-listen` 即可开启：

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
# 输出中会显示 [api] token: …
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health
```

每次启动都会生成新的 token。要使用固定的 token，请设置环境变量 `VPHONE_API_TOKEN`。不带 token 的请求和来自网页的请求都会被拒绝。接口说明见 [API 文档](../Research/vphoned_http_api.md)。

## 遇到问题

请先查看[故障排查](Guides/troubleshooting.md)，其中包括虚拟机程序被系统拒绝、恢复失败、停在 “Press home to continue” 等情况。如果仍未解决，请[提交 issue](https://github.com/Lakr233/vphone-cli/issues)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [宿主机设置](Guides/host-setup.md) | SIP 与 AMFI 设置、源码构建、环境检查 |
| [创建与运行](Guides/create-and-run.md) | 固件来源、创建流程、存储与备份 |
| [兼容性说明](Guides/compatibility.md) | 已验证的固件组合 |
| [故障排查](Guides/troubleshooting.md) | 常见错误及解决方法 |
| [Launchpad 命令行](Guides/launchpad-cli.md) | 用 `vphone-launchpad-cli` 安装和测试本地构建 |
| [研究记录](../Research/README.md) | 补丁与实现细节 |

## 项目结构

- `vphone-launchpad`：Mac App，负责下载和安装 `VPhone.bundle`、配置宿主机。单独发布。
- `vphone-cli`：准备固件、打补丁、恢复系统、管理虚拟机。
- `vphone-vm`：运行虚拟机并显示虚拟机窗口。
- `vphoned`：虚拟机中的控制服务，窗口中的功能和 API 都通过它实现。

| 路径 | 内容 |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | `vphone-cli`、`vphone-vm`、固件补丁与恢复 |
| [`VPhoneKit/`](../VPhoneKit/) | 宿主机共享库与 API 客户端 |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | 虚拟机中的 hook 与辅助程序 |
| [`VPhoneLaunchpad/`](../VPhoneLaunchpad/) | Launchpad App 及其辅助程序 |

从源码构建：`xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build`，产物为 `VPhone.bundle`。

## 致谢

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
