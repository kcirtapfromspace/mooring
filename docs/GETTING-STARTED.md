# Get started with Mooring

Use Mooring to view and control another computer from your Mac.
Mooring is free and open source.
You do not need a Mooring account.

## Check compatibility

| Computer | Current download: preview 45 |
| --- | --- |
| Viewing Mac | Apple silicon, macOS 14 or later |
| Sharing Mac | Apple silicon, macOS 14 or later; install the same preview |
| Linux desktop | Experimental Omarchy/Hyprland support; requires SSH and wayvnc with RSA-AES sign-in |

Mac-to-Mac sessions include shared clipboard, sound, and trackpad gestures.
These features are not available for Linux desktops.
Large screen updates on Linux can be slow.
Ubuntu/X11, Jetson, and built-in Internet Links require a current source build.
They are not in preview 45.

## Install on your Mac

1. [Download the preview 45 ZIP](https://github.com/kcirtapfromspace/mooring/releases/download/v0.3.0-preview.45/Mooring-v0.3.0-preview.45-macos-arm64.zip).
2. Open the ZIP to extract `Mooring.app`.
3. Quit an existing Mooring installation before replacing it.
4. Move `Mooring.app` to Applications.
5. Open Mooring from Applications.

For Mac-to-Mac use, install the same preview on both Macs.
An existing installation can use **Check for Updates…** in the Mooring menu.

## Connect two Macs

Start with both Macs on the same network.
The sharing Mac is the computer you want to control.
The viewing Mac is the computer in front of you.

1. Unlock the sharing Mac.
2. Choose **Show Pairing PIN…** from its Mooring menu.
3. Choose **Pair a Mac…** on the viewing Mac.
4. Select the sharing Mac from the list.
5. Enter the six-character PIN shown on the sharing Mac.
6. Choose **Pair**.
7. Open **Share this Mac…** on the sharing Mac.
8. Choose **Start sharing**.
9. Allow Mooring to record the screen when macOS requests permission.
10. Choose **Enable Keyboard & Mouse…** on the sharing Mac.
11. Allow Mooring in **System Settings → Privacy & Security → Accessibility**.
12. Select the paired Mac on the viewing Mac.
13. Choose **Connect**.

If the sharing Mac does not appear, choose **Enter an address…** in the pairing window.
Enter its network address, then enter its PIN.
If macOS requests a restart after a permission change, reopen Mooring and start sharing again.

Screen recording permits viewing.
Accessibility permits keyboard and mouse control.
On the viewing Mac, Accessibility also lets Mooring send system shortcuts such as Command-Tab to the sharing Mac.

Choose **Stop Sharing This Mac** to stop access now.
Remove the pairing in Mooring Settings to revoke that Mac's approval.

## Connect an Omarchy desktop

Linux requires manual setup.
Mooring does not install the Linux services for you.

Before you connect, configure these services on Linux:

- SSH with key authentication from your Mac.
- wayvnc with RSA-AES sign-in, listening on `127.0.0.1:5900`.

Keep VNC accessible through SSH only.
Configure the services with the Linux computer's owner or administrator.

1. Confirm that `ssh YOUR_HOST` connects from your Mac without a password or host-key prompt.
2. Choose **Add Linux Desktop** in Mooring on your Mac.
3. Enter the same SSH alias or `user@host` destination.
4. Choose **Connect**.
5. Enter the Linux desktop account credentials in Mooring's sign-in dialog.

Leave **More Options** at `127.0.0.1:5900` unless your VNC server uses another local port.
Mooring does not save the desktop password.
Unlock a locked Linux desktop on that computer before connecting.

See the [preview 45 notes](release-notes-v0.3.0-preview.45.md) for tested versions and current limits.

## Connect away from home

The current download needs a reachable network address.
It does not establish an Internet route for you.

1. Connect both computers to a VPN that permits connections between them.
2. Check that the other computer is reachable through that VPN.
3. Pair the Macs using the sharing Mac's VPN address if necessary.
4. For Linux, use an SSH destination reachable through the VPN.
5. Connect in Mooring as usual.

Keep the other computer powered on and available.
Unlock a sharing Mac before connecting.
Mooring does not provide a VPN service.

Built-in Internet Links are experimental and require source builds and manual configuration.
They are not in the signed download.
See the [experimental setup and limits](INTERNET-CONNECTIVITY.md) before trying them.

## Get help

If connection fails, check sharing, permissions, network reachability, and the installed version on each computer.
For Linux, confirm SSH and wayvnc work before reconnecting.

[Report a problem](https://github.com/kcirtapfromspace/mooring/issues) with your computer models, operating systems, Mooring version, and the displayed error.
Keep passwords, PINs, clipboard contents, and private desktop images out of the report.
