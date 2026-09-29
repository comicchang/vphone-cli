<div align="right"><a href="Documents/README.md">Docs</a> · <strong>English</strong> · <a href="Documents/README_zh.md">中文</a> · <a href="Documents/README_ja.md">日本語</a> · <a href="Documents/README_ko.md">한국어</a></div>

# vphone-cli

Run a virtual iPhone on an Apple Silicon Mac.

![Virtual iPhone running on macOS](Documents/demo.jpeg)

vphone-cli runs iOS with Apple's Virtualization.framework and PCC research virtual machines, for security research, reverse engineering, and debugging.

- **Graphical Window:** Use the virtual iPhone's screen on your Mac, browse apps and files, and take screenshots and screen recordings.
- **Custom Firmware:** The system comes pre-patched, and you can install a package environment.
- **Backup and Cloning:** You can export, import, and clone VMs.
- **Automation API:** An optional local HTTP and WebSocket interface.
- **No Extra Dependencies:** Needs no Xcode, Python, or Homebrew at runtime.

> For 1.x, see the [1.0.14 release](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14). Version 2.x cannot start VMs created by 1.x. You need to create them again.

## Requirements

- A physical Apple Silicon Mac running macOS 15 or newer. It does not work in a macOS VM.
- Enough disk space. Each VM uses a 64 GB virtual disk by default, and firmware and temporary files take additional space.
- A network connection. Restoring the system fetches signing tickets online.
- Adjusted security settings. Boot into macOS Recovery, run these commands in Terminal, then restart:

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP stays enabled, with only the debugging restrictions relaxed. For the reasons and other ways to set this up, see [Host Setup](Documents/Guides/host-setup.md).

## Get Started

1. Download the latest [vphone-launchpad](https://github.com/Lakr233/vphone-cli/releases/latest) (`vphone-launchpad-<version>.zip`), unzip it, and open it.
2. In **Host Setup**, grant Developer Tools access and install the helper.
3. In **Core Bundle**, click **Download and Install**. Launchpad downloads and verifies `VPhone.bundle`, then allows the VM program inside it to run on your Mac.
4. In **Machines**, click **New Machine**, choose a firmware pairing, and click **Create**.

Launchpad downloads the firmware, patches it, restores the system, and boots it for the first time. When it finishes, the VM keeps running.

You can also use your own iPhone and cloudOS IPSWs. For verified pairings, see [Compatibility](Documents/Guides/compatibility.md).

## Install the Package Environment

The VM has no package manager by default. To install one:

1. In the menu bar, choose **Apps > Install Bootstrap…** and select the **roothide** layout (**rootless** is deprecated). This installs Irisin in the VM.
2. The first time, select `apt` and `bash` in Irisin, press and hold the install button, and choose **Bootstrap Install**. `bash` and `debianutils` depend on each other, so a normal install cannot complete.
3. After that, use a normal install.

To remove the environment, choose **Apps > Uninstall Bootstrap…**. The VM restarts after removal.

Hold Option while opening the **Apps** menu to see two more options:

- **Install Bootstrap from File…:** Installs from a local Irisin `.deb`.
- **Uninstall Bootstrap Without Restarting…:** Removes the environment without restarting the VM.

## Command Line

Launchpad manages VMs through the `vphone-cli` inside `VPhone.bundle`. You can also use it directly in Terminal:

| Task | Command |
| --- | --- |
| List VMs | `vphone-cli vm list` |
| Show VM information | `vphone-cli vm info myphone` |
| Start a VM | `vphone-cli vm launch myphone` |
| Stop a VM | `vphone-cli vm stop myphone` |
| Clone a VM | `vphone-cli vm clone myphone copy` |
| Export a VM | `vphone-cli vm export myphone --out myphone.tzst` |
| Import a VM | `vphone-cli vm import myphone.tzst --name restored` |

VMs are stored in `~/.vphone/` by default. Run `vphone-cli <group> --help` to see all commands. To create a VM without Launchpad, see [Create and Run](Documents/Guides/create-and-run.md).

### Automation API

Add `--api-listen` at launch to turn it on:

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
# The output shows [api] token: …
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health
```

Each launch generates a new token. To use a fixed token, set the `VPHONE_API_TOKEN` environment variable. Requests without the token and requests from web pages are refused. For the interface reference, see the [API documentation](Research/vphoned_http_api.md).

## Troubleshooting

Start with [Troubleshooting](Documents/Guides/troubleshooting.md), which covers cases such as the system refusing the VM program, restore failures, and getting stuck on "Press home to continue". If that does not solve it, [open an issue](https://github.com/Lakr233/vphone-cli/issues).

## Documentation

| Document | Contents |
| --- | --- |
| [Host Setup](Documents/Guides/host-setup.md) | SIP and AMFI settings, building from source, environment checks |
| [Create and Run](Documents/Guides/create-and-run.md) | Firmware sources, the creation process, storage and backups |
| [Compatibility](Documents/Guides/compatibility.md) | Verified firmware pairings |
| [Troubleshooting](Documents/Guides/troubleshooting.md) | Common errors and how to fix them |
| [Launchpad Command Line](Documents/Guides/launchpad-cli.md) | Install and test a local build with `vphone-launchpad-cli` |
| [Research Notes](Research/README.md) | Patch and implementation details |

## Project Structure

- `vphone-launchpad`: A Mac app that downloads and installs `VPhone.bundle` and sets up the host. Released separately.
- `vphone-cli`: Prepares firmware, patches it, restores the system, and manages VMs.
- `vphone-vm`: Runs the VM and shows its window.
- `vphoned`: The control service inside the VM. The window's features and the API work through it.

| Path | Contents |
| --- | --- |
| [`VPhoneExecutable/`](VPhoneExecutable/) | `vphone-cli`, `vphone-vm`, firmware patching and restore |
| [`VPhoneKit/`](VPhoneKit/) | Shared host libraries and API client |
| [`VPhoneDaemon/`](VPhoneDaemon/) | `vphoned` |
| [`VPhoneGuestComponents/`](VPhoneGuestComponents/) | Hooks and helper programs inside the VM |
| [`VPhoneLaunchpad/`](VPhoneLaunchpad/) | The Launchpad app and its helper |

To build from source, run `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build`. The output is `VPhone.bundle`.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
