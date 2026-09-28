# Launchpad command line

`vphone-launchpad-cli` ships in `vphone-launchpad.app/Contents/MacOS`. It
drives the running Launchpad over a Unix socket at
`~/Library/Application Support/vphone-launchpad/control.sock` (mode 0600,
served only to the same user) and starts Launchpad in the background when it
is not running. It has no privileges and no state of its own: bundles are
installed through Launchpad's helper, machines run through the active
bundle's `vphone-cli`, and every command appears in Launchpad's window and
command history. Nothing listens on the network; reach it over ssh from
another machine.

Progress lines go to stderr as they arrive. The result is one JSON document on
stdout. The exit status is 0 on success and 1 on failure, with the reason on
stderr. Interrupting the CLI cancels a command that can be cancelled
(`exec`, waits, CFW install); a bundle install or machine creation belongs to
the window and keeps running.

```sh
ln -s /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli /usr/local/bin/
vphone-launchpad-cli help
```

## Testing a VPhone.bundle build

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build

# Installs as <version>-local, makes it active, adds the execution policy
# exception, allows the new vphone-vm cdhash and runs host preflight.
vphone-launchpad-cli bundle install-local .build/XcodeBundle/Build/Products/Debug/VPhone.bundle

vphone-launchpad-cli vm start research-01 --wait
vphone-launchpad-cli guest rpc research-01 device.info
vphone-launchpad-cli guest rpc research-01 apps.list '{}'
vphone-launchpad-cli vm log research-01 --lines 100
vphone-launchpad-cli vm stop research-01

# The same checks against the release it replaces.
vphone-launchpad-cli bundle use 2.0.9
```

The first step that needs the helper after its five-minute authorization
expires asks for an administrator password on the Mac, as the window does.

## Commands

| Command | Does |
| --- | --- |
| `status` | Host checks, helper, active bundle, machine counts |
| `bundle list` | Installed versions, receipts, cdhashes and check results |
| `bundle install-local <path>` | Install a local `VPhone.bundle` folder or `.zip` |
| `bundle install-release <version\|latest>` | Download and install a GitHub release |
| `bundle use <version>` / `bundle verify <version>` | Switch to or re-check an installed version |
| `bundle accept <version> [--off]` / `bundle remove <version>` | Skip failed checks, or remove a version |
| `vm list` | Machines in every library with run state and log path |
| `vm start <name> [--headless] [--wait]` / `vm stop <name>` | Launch or stop; `--wait` waits for vphoned |
| `vm wait <name>` / `vm log <name> [--kind create\|dfu\|patch]` | Wait for vphoned; read a console log |
| `vm create <name> [...] [--from <step>]` | The New Machine pipeline; `--from` retries from a step |
| `cfw install <name>` | Install CFW into a stopped machine through the helper |
| `guest send <name> <json>` | One raw `vphone.sock` request (tap, swipe, key, screenshot) |
| `guest rpc <name> <method> [params]` | Any vphoned method, see `Research/vphoned_http_api.md` |
| `exec <vphone-cli arguments>` | Run the active bundle's `vphone-cli`, streaming its output |

Machine commands take `--root <library>` when two libraries hold a machine
with the same name. `guest` commands and `--wait` go through the machine's
`vphone.sock`, which every launch serves; bundles up to 2.0.9 serve it only
for machines launched with a window.
