# Internet prototype validation — 2026-11-14

Built locally on the Apple-silicon development Mac, with the repository's pinned
Rust/Xcode toolchains. Iroh is pinned to 1.4.1. No GitHub Actions or remote
compilation was used. This is an ad-hoc-signed development build, not a notarized
release or public update.

| Check | Result |
| --- | --- |
| Full `scripts/ci-local.sh` | Passed: 366 Rust tests, strict Clippy, normal native suites, complete normal app build and packaged CLI integration |
| Final session/connectivity tests after shutdown and CLI refinements | Passed: 186 session + 10 connectivity tests; strict all-feature Clippy rerun |
| Disabled internet ABI | Passed: rejects calls and clears output buffers |
| Native suites linked with internet enabled | Passed: session (281 checks), display topology (59), privacy (27), input (125), virtual-display boundary (49), menu, VNC, media and application workflows |
| Native encrypted media fixture | Passed: 120/120 1080p frames, return controls, telemetry, clipboard, pointer shape, Opus and HEVC 4:4:4; local loopback only |
| Direct QUIC fixture | Passed: real payload and existing Noise pairing, saved-device reconnection and control messages over loopback |
| Forced-relay fixtures | Passed: real payload and Noise sessions, with direct IP transport disabled |
| Authorization and cleanup | Passed: unapproved endpoint/service rejection, wrong pinned Noise host with otherwise valid saved-device authentication, expiring/bounded locators, sticky cancellation, local listener cleanup and shared host/viewer lifetime |
| Final packaged helpers → Omarchy over forced relay | Passed: SSH authentication and known-host verification retained; read-only command; 3.72 seconds including fixture setup |
| Final packaged helpers → Jetson over forced relay | Passed: same checks; 27.46 seconds including fixture setup on its older system |
| Direct-only live Omarchy check | Timed out during SSH banner exchange on this network; not claimed as passed |
| App packaging | Passed: arm64-only executables, signed helper, deep/strict signature verification, locked dependency notices |
| Linux packaging | Passed: locally cross-compiled arm64/glibc 2.27 binary, separate Linux notices and SHA-256 checksum |

The live checks explicitly selected `https://usw1-1.relay.n0.iroh.link.` and
disabled direct IP transports. Disposable transport identities were generated
on their owning devices. Only a temporary helper was deployed, then removed.
The SSH commands were `printf` and `uname`; no desktop was opened or unlocked.
Existing connections, credentials and installed services were preserved.

A separate raw UDP echo fixture also timed out when sending to this Mac's own
LAN address, while loopback worked. This supports investigating the local
network/permission path, but does not identify its cause. Relay mode is the
verified route for trying this build on the current network.

Local evidence is retained under `target/internet-validation/` and is intentionally
untracked. The transferable artifacts are `dist/Mooring-Internet-macos-arm64.zip`
and `dist/mooring-link-linux-arm64.tar.gz`, with hashes in
`dist/internet-prototype.sha256`.

Still unverified: a real two-Mac desktop/media session over this transport,
direct connectivity across different NATs, downloaded/notarized app behavior,
and a complete Linux desktop session through an app-managed internet route.
The Linux helper currently integrates through SSH ProxyCommand; app route
settings, locator exchange and background service installation remain future
product work. See [the usage and architecture guide](INTERNET-CONNECTIVITY.md).


## Delivery validation — 2026-11-15

The delivery candidate is preview 46, build 51.
Source builds include the Internet menu and helper by default.
The signed public download remains preview 45 until notarization is complete.

The preceding live demonstration displayed the Jetson's graphical desktop in Mooring at 1800×1135.
Direct IP transport was disabled.
The demonstration used one owned SSH connection for VNC, desktop checks, and display cleanup.
The first attempt used separate proxy processes and disconnected during sign-in.
The working connection reused one authenticated SSH connection.
No desktop password or lock-screen input was submitted.
No captured desktop image was added to public source.

The helper now supplies this lifetime through `mooring-link ssh-session`.
The generated configuration retains SSH host-key verification.
Its control socket separates remote hosts, ports, and accounts.
The command stops its owned processes and removes the configuration on exit.

| Delivery check | Result |
| --- | --- |
| Full local CI | Passed: 369 Rust tests, strict Clippy, native suites, media fixtures, app build, and packaged CLI integration |
| Owned SSH helper tests | Passed: private configuration, target validation, process reaping, and early-failure cleanup |
| Live Omarchy owned session | Passed: two concurrent SSH channels over a forced relay; separate account control paths; configuration removed |
| Live Jetson owned session | Passed: two concurrent SSH channels over a forced relay; configuration removed |
| Disabled ABI | Rejecting stub behavior remains available with the Internet feature disabled |
| Documentation | File links, site anchors, repository links, and static assets checked; desktop and 390-pixel layouts inspected; download dropdown and Escape dismissal checked |
| Public release | Pending Developer ID signing and Apple notarization; no valid local signing identity was found |

The graphical demonstration used the temporary orchestration before `ssh-session` was added.
The delivered helper has separate automated and live SSH checks.
A graphical session through that exact packaged command remains a separate acceptance check.
The Linux app form still has no locator field.
Real two-Mac Internet desktop streaming and direct connectivity across different NATs remain unverified.


The compact landing page has 324 words, approximately 77% fewer than its expanded revision.
The README has 322 words, approximately 75% fewer.
Setup and architecture detail remain in linked documents and native disclosure controls.
The existing approved Mac recording remains the product visual.
No new captured desktop image was published.

The final packaged helpers passed on both devices with two concurrent SSH channels.
The Omarchy check completed in 4.47 seconds; the Jetson check completed in 27.36 seconds.
Both checks confirmed account-specific control paths and removal of the private configuration.
