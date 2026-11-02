# Host setup

[Documentation](../README.md) · [Create a VM](create-and-run.md) · [Troubleshooting](troubleshooting.md)

The VM needs an Apple Silicon Mac running macOS 15 or newer. PV=3 research guests do not run inside a nested macOS VM. The signed `vphone-vm` companion carries Apple-private virtualization entitlements; the unentitled `vphone-cli` entry point can still print a useful error if the host refuses it.

## Build and preflight

A distributed `.bundle` needs no Homebrew, Python or Xcode **at runtime**. A source build needs Xcode and its iPhoneOS SDK to compile vphoned. From a source checkout:

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli host preflight
```

Build the `VPhone` scheme in Xcode to produce the ad hoc signed bundle with all companion binaries. `host preflight` checks the entitled companion before any VM is started. If AMFI refuses it, the error prints the bundled allowlist helper command.

## Permit the entitled VM binary

These are host policy choices, performed by the machine owner. Both require `csrutil allow-research-guests enable` in Recovery. Choose one path.

### A. Disable SIP and AMFI

In macOS Recovery, open Terminal:

```sh
csrutil disable
csrutil allow-research-guests enable
```

After rebooting into macOS, set the boot argument and reboot again:

```sh
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

This is the more permissive host configuration. Review existing `boot-args` before replacing them.

### B. Keep SIP enabled with debugging restrictions relaxed

In macOS Recovery:

```sh
csrutil enable --without debug
csrutil allow-research-guests enable
```

After rebooting, allowlist the **current signed build**. In a source checkout:

```sh
bundle=.build/XcodeBundle/Build/Products/Debug/VPhone.bundle
sudo "$bundle/Contents/MacOS/vphone-escalator" allow "$bundle/Contents/MacOS/vphone-vm"
"$bundle/Contents/MacOS/vphone-escalator" status
"$bundle/Contents/MacOS/vphone-cli" host preflight
```

The helper creates the AMFI code-requirements preference if absent. If it exists, it appends the current `vphone-vm` cdhash to its `Entitlements` requirement, preserving other cdhashes and preference keys. It leaves any existing `AllowUnsafeDynamicLinking` value untouched and writes `false` only when that key is absent. It avoids duplicate hashes and enables amfid to consult the requirement by changing one byte in its heap. **Repeat the `allow` command after every build**, including a rebuild that only changes the signature. You may pass additional signed host binaries to the same `allow` command when they need restricted entitlements; the unentitled `vphone-cli` does not need this. `sudo "$bundle/Contents/MacOS/vphone-escalator" off` removes only hashes added by this helper and restarts amfid. It preserves the preference and its other values.

### In-memory admission and `--hold N` mitigation

The preference plist persists across reboots, but `amfid` only reads it while its in-memory gate (`_isRunningInternalBuild`) is set to `1`. Because `amfid` is an on-demand system daemon with `EnablePressuredExit`, launchd routinely terminates idle instances (every 30–120 minutes) or reclaims them under memory pressure. Every new `amfid` instance starts with this byte reset to `0`, causing subsequent `vphone-vm` launches to fail with `SIGKILL (Code Signature Invalid)` until re-allowed.

To mitigate frequent `amfid` restarts during local development and testing, `vphone-escalator` supports a native hold option:

```sh
sudo "$bundle/Contents/MacOS/vphone-escalator" allow --hold 3600 "$bundle/Contents/MacOS/vphone-vm"
```

The process runs in the foreground, polling `amfid` every 200 ms. Whenever `amfid` restarts during the hold duration, it re-attaches, re-writes the heap byte, and triggers requirement reload.

- **Use case:** Active test suites, development sessions, or environments where frequent jetsam exits disrupt VM launches.
- **Limitations:** Runs synchronously in the foreground until the timeout expires or interrupted with Ctrl-C; requires root privileges; does not install as a persistent daemon.

For a distributed bundle without a source checkout, run `vphone-cli host preflight` first. If AMFI refuses the guest, its error gives the full `sudo .../vphone-escalator allow .../vphone-vm` command for that bundle.

In `vphone-launchpad`, bundle preflight checks that SIP debugging restrictions are disabled (or SIP is fully disabled) and Research Guests is enabled. When a newer app includes a newer SMJobBless helper, Launchpad asks for administrator authorization to update the helper at startup. If the installed `vphone-vm` is blocked by AMFI, the helper checks those host settings again, verifies the root-owned bundle and its recorded cdhash, runs that bundle's `vphone-escalator allow` as root, and Launchpad repeats preflight. Each new bundle signature is checked and allowed separately.

Automatic self-healing (watching for rapid launch exits and re-verifying through the helper) is implemented in unreleased 2.15.0-dev builds. In installed 2.14.x application releases, Launchpad refuses the start and reports the manual command. When `vphone-cli vm launch` is blocked by AMFI, running the printed `sudo .../vphone-escalator allow` command re-applies admission. Alternatively, if `vphone-launchpad` is already running on the Mac, standalone CLI users can run `vphone-launchpad-cli bundle verify <version>` for a one-line relief that re-applies the allowlist through Launchpad's privileged helper without requiring manual sudo.

## What the build contains

`vphone-cli` orchestrates the work without private entitlements and handles archives through `vphone-cli archive`. `vphone-vm` is the signed, entitled GUI/VM process. The bundle also contains `vphoned`, compiled for iOS at build time; it is installed into each created guest. The [research notes on the binary split](../../Research/Host/host_binary_split.md) record the implementation history, including superseded approaches.
