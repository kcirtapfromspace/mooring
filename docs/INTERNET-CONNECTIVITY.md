# Internet Links

Internet Links provides direct or relay connectivity for Mooring.
Iroh 1.4.1 implements QUIC in Rust.
The feature is experimental and included in current source builds.
The signed public preview 45 does not include it.

## Before you start

Use an Apple silicon Mac with macOS 14 or later.
Use current source builds on both Macs for native Internet sessions.
Keep an existing pairing between those Macs.
Use an operator-selected HTTPS Iroh relay when direct UDP is unavailable.
Mooring does not operate a hosted relay.

Internet connectivity does not authorize desktop access.
The native session still requires Noise authentication.
Linux still requires SSH authentication and host-key verification.
A relay can observe network metadata and encrypted traffic.
No public endpoint discovery publisher is enabled.

## Connect two paired Macs

1. Open Mooring on the viewing Mac.
2. Choose **Mooring → Internet Connections (Experimental) → Copy Internet ID**.
3. Start sharing on the sharing Mac.
4. Choose **Share over Internet…** on the sharing Mac.
5. Enter the viewing Mac's Internet ID.
6. Enter the HTTPS relay URL, or leave the field empty for direct connectivity.
7. Choose **Create Locator**.
8. Send the copied locator to the viewing Mac.
9. Select the paired sharing Mac on the viewing Mac.
10. Choose **Connect Selected Mac over Internet…**.
11. Paste the locator and choose **Connect**.

The Mac stores its separate transport identity in Keychain.
The locator contains addresses and expires after ten minutes.
It does not contain a pairing secret.
Mooring keeps the temporary route in memory.
The saved LAN and VPN addresses remain unchanged.

Choose **Use Saved Network Address** to remove the temporary route.
Stop Sharing to stop the Internet listener.
To change the approved endpoint or create another locator, stop sharing and start sharing again.

## Prepare the Linux helper

The helper supports Linux arm64 with glibc 2.27 or later.
Build the Linux package on the local Apple silicon Mac:

```sh
./scripts/build-internet-helper-linux.sh
```

The build requires Zig 0.14.1 and cargo-zigbuild 0.24.1.
It also requires the Rust `aarch64-unknown-linux-gnu` target.
The package includes the executable, license notices, and a checksum.
The Mac app includes its own `Contents/Resources/mooring-link` executable.

Create a transport identity on each owning device:

```sh
mooring-link identity /private/path/host.key
mooring-link identity /private/path/client.key
```

Run the first command on Linux and the second command on the viewing Mac.
Each command prints a public Internet ID.
The private seed stays in its new file.
The helper rejects an existing destination file.
It requires current-user ownership and no group or other file permissions when reading a key.

## Start the Linux endpoint

Run this command on Linux:

```sh
mooring-link serve \
  --key /private/path/host.key \
  --allow CLIENT_PUBLIC_ID \
  --service ssh \
  --relay https://YOUR-RELAY \
  --relay-only
```

Replace `CLIENT_PUBLIC_ID` with the viewing Mac's public Internet ID.
Replace the relay URL with the selected operator's address.
The helper forwards only to the host's loopback SSH port 22.
An incoming peer cannot select another host or service.

Save the `ticket` string from the ready message in a file on the viewing Mac.
Save the string itself, not the enclosing ready message.
Use the locator within ten minutes.
Stop the Linux endpoint with Control-C when you finish.
It stops automatically after one hour.

## Open a Linux desktop through the relay

Use `ssh-session` for the complete Mooring workflow.
The workflow uses concurrent channels for video, desktop checks, and display cleanup.
The helper keeps these channels on one authenticated SSH connection.
Separate proxy processes must not register the same transport identity at one relay.

1. Quit the Mac app instance that will use the temporary route.
2. Start the Linux endpoint with the approved Mac Internet ID.
3. Save the locator in `/private/path/host.ticket` on the Mac.
4. Run the command below with the Mac helper.
5. Select the existing Linux desktop in Mooring.
6. Choose **Connect**.
7. Quit that Mooring instance to end the owned relay session.

```sh
mooring-link ssh-session \
  --key /private/path/client.key \
  --ticket /private/path/host.ticket \
  --service ssh \
  --target YOUR_EXISTING_SSH_ALIAS \
  --relay https://YOUR-RELAY \
  --relay-only \
  -- /Applications/Mooring.app/Contents/MacOS/Mooring
```

Use the same SSH alias that the saved Linux desktop uses.
Keep its existing hostname and known-host entry.
The helper does not disable host-key checking.
The helper does not request an SSH password.
A new host must have a trusted known-host entry before this command succeeds.

The helper creates a private configuration and Unix control socket.
The socket name separates SSH hosts, ports, and user accounts.
The child command receives the configuration path in `MOORING_SSH_CONFIG`.
Mooring's app and CLI read this variable.
Other commands must explicitly use that configuration to use this route.

The helper stops the owned command and SSH process on cancellation, connection failure, or session expiry.
It removes the temporary configuration on exit.
It does not change the user's SSH configuration or install a persistent service.
The Linux connection form does not yet select a locator.

## Single-channel diagnostics

`proxy` supplies a byte stream for one SSH process:

```sh
ssh -o 'ProxyCommand=/absolute/path/mooring-link proxy --key /private/path/client.key --ticket /private/path/host.ticket --service ssh --relay https://YOUR-RELAY --relay-only' \
  YOUR_EXISTING_SSH_ALIAS
```

Use `ssh-session` when more than one channel or process is required.
`connect` prints a temporary loopback address for other diagnostic tools.
`local-proxy` is the loopback-only adapter used by the owned SSH session.
It creates no Iroh identity and writes no status text to the protocol stream.

## Build options

```sh
./scripts/build-app.sh
open dist/Mooring.app
```

Source builds include the experimental Internet menu and helper by default.
Use `MOORING_EXPERIMENTAL_INTERNET=0` to build the rejecting ABI stubs.
A development build uses ad hoc signing unless a signing identity is supplied.
A public Mac download requires Developer ID signing and notarization.

## Limits and recovery

| Condition | Result or recovery |
| --- | --- |
| Locator expires | Ask the sharing device for a new locator. |
| Direct connection fails | Select an explicit HTTPS relay. |
| Wrong Internet ID | The host rejects the endpoint. |
| Wrong native pairing | Noise rejects the session, even if the endpoint was approved. |
| Unknown SSH host key | Verify and establish the host key through the normal trusted SSH workflow. |
| SSH connection fails | The owned command stops and its private configuration is removed. |
| Same identity, conflicting relay settings | The process rejects the second configuration. |
| Server reaches 64 attempts | Restart the explicit hosting session. |
| Session reaches one hour | Create a new session and locator. |

Direct-only live testing timed out on the current test network.
Forced-relay SSH passed on Omarchy and the Jetson.
A Jetson graphical desktop was displayed in Mooring over the forced relay.
A real two-Mac desktop session through the new transport remains unverified.
See [validation](INTERNET-VALIDATION.md) and [architecture limits](ARCHITECTURE.md#resource-limits).
