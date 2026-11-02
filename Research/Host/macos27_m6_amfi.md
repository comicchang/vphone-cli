# macOS 27 / Apple M6 AMFI host notes

On Apple M6 with macOS 27.0 (26A428), `amfid` runs as `ARM64E.X1` rather than the plain `arm64e` slice. The AMFI framework's shared-cache addresses differ between those architecture variants.

`VPhoneEscalator` derives the `AMFIRequirementsManager` singleton slot from its own copy of `+[AMFIRequirementsManager sharedManager]`, then reads the same slot in `amfid`. A plain-arm64e escalator therefore derives the wrong shared-cache slot when `amfid` is X1. The failure presents as an invalid remote pointer such as `0x73db0000ffffffff` and `mach_vm_read_overwrite` returns `KERN_INVALID_ADDRESS`.

The supported build fix is to ship `vphone-escalator` as a fat Mach-O containing both `arm64e` and `arm64e.x1`. dyld then selects the architecture variant matching the host, so the slot derivation uses the same shared-cache layout as `amfid`.

The escalator also strips pointer-authentication/tag bits from the remote singleton pointer using `machdep.virtual_address_size`, matching the upstream `Lakr233/amfi-allow` fix merged in PR #1 (`strip-pac-vm-reads`).

## Validation on M6

1. Confirm `/usr/libexec/amfid` is reported as `ARM64E.X1` by `vmmap`/process metadata.
2. Build `VPhoneEscalator` with `ARCHS="arm64e arm64e.x1"` and `ONLY_ACTIVE_ARCH=NO`.
3. Confirm `file`/`lipo -info` report both `arm64e` and `arm64e.x1` slices.
4. Run `vphone-escalator status` as root. The singleton slot must resolve to a mapped `AMFIRequirementsManager`, its isa class bits must match, and both boolean ivars must read as 0 or 1.
5. Do not attempt the `allow` write path until the read-only status check succeeds.

This fix does not disable SIP, patch executable code in `amfid`, or change `vm.cs_system_enforcement`.

## Bundle staging

`StageBundle.sh` must not pin the Escalator build to `-destination 'platform=macOS,arch=arm64e'`: Xcode treats that destination as an active-architecture constraint and emits a thin `arm64e` executable even when the project `ARCHS` contains both variants. The staging build therefore passes `ARCHS="arm64e arm64e.x1"` and `ONLY_ACTIVE_ARCH=NO` explicitly and does not set an arm64e-only destination.

## In-memory admission lifetime and `--hold` mitigation

Allowlisting via `vphone-escalator allow` operates on two layers:
1. **Persistent preference plist:** Adds the binary's cdhash to the system code-requirements preference plist under the `Entitlements` requirement.
2. **Volatile in-memory gate:** Changes a single byte `_isRunningInternalBuild = 1` in `amfid`'s remote heap (within `+[AMFIRequirementsManager sharedManager]`), which enables `amfid` to consult that requirement on retail macOS builds.

### Why in-memory admission is lost

`amfid` is managed by launchd with `EnablePressuredExit`. Routine idle exits (typically every 30–120 minutes) or system memory pressure terminate `amfid`. When launchd respawns `amfid`, the new process initializes with a pristine heap where `_isRunningInternalBuild` is `0`. Although the preference plist is intact, the new `amfid` instance ignores it. The next `vphone-vm` launch is immediately killed by the kernel with `SIGKILL (Code Signature Invalid)`.

### Escalator `--hold N` mechanism

To avoid repeated manual intervention during active development and test workflows, `vphone-escalator` implements a native monitoring loop via `--hold N`:

```sh
sudo vphone-escalator allow --hold 3600 <binary>...
```

**Implementation details (`cmd_allow` in `Commands.c`):**
- Escalator updates the preference plist, writes `_isRunningInternalBuild = 1`, and waits up to 3 seconds for `amfid` to adopt the requirement (`trigger_reload()`).
- If `hold_seconds > 0`, it enters a poll loop sleeping 200 ms per iteration.
- On each tick, it verifies whether `find_amfid() == g_amfid`.
- If the PID differs (indicating `amfid` restarted), it deallocates the stale Mach task port, attaches to the new `amfid` instance via `task_for_pid`, resolves the `AMFIRequirementsManager` singleton, re-writes `_isRunningInternalBuild = 1`, and re-triggers preference reload via `trigger_reload()`.
- The loop continues until `hold_seconds` elapses or the user terminates it with `SIGINT` (Ctrl-C).

**Applicability and constraints:**
- **Applicable scenarios:** Active local debugging, continuous automated testing, and development sessions subject to frequent `amfid` jetsam exits.
- **Constraints:**
  - Operates as a synchronous, blocking foreground command.
  - Requires persistent root privileges (`sudo`).
  - Does not install as a persistent system daemon or launchd LaunchDaemon (by design, to avoid expanding persistent root attack surface).
  - For unattended environments or GUI-driven flows, on-demand re-verification (via Launchpad root helper or `vphone-launchpad-cli bundle verify <version>`) provides the alternative on-demand remediation.
