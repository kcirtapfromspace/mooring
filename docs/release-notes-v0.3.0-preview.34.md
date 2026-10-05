# Mooring 0.3.0 preview 34 — Recent Macs and sharing status

The menu now gives your recently connected paired Macs their own section. It shows the last three, with earlier connections under **More Macs**. The connected Mac has a checkmark; choosing it returns to its viewer. The order uses the existing Rust connection history and survives restarting Mooring.

When this Mac starts capturing its screen for a connected viewer, the Mooring menu bar logo gains an outgoing sharing badge. The badge clears when capture stops, including a disconnect or capture restart. Waiting for a viewer keeps the plain logo. The tooltip and accessibility label describe the current status.

The purple macOS screen-sharing indicator remains separate and controlled by macOS. Apple Screen Sharing Macs stay in their existing submenu. Saved addresses, pairings, credentials and preferences carry forward.

## Validation

The full local CI suite passed on Apple silicon: Rust formatting, linting and 232 tests; native media, input, session, privacy and display checks; encrypted loopback streaming; packaged CLI checks; and the arm64 macOS 14 app build. The new menu checks cover 1, 3, 4 and 32 peers, connection routing from the quick list and More Macs, order, the connected marker, busy states, long names and the sharing icon. An isolated native UI preview verified the menu and logo with fixture devices.

Local checks do not verify a real session between two Macs, live badge transitions, downloaded-app launch or Apple mode switching. On the test Macs, connect and disconnect a paired session and verify that the sharing Mac's logo gains and clears its badge. With more than three saved pairings, verify that More Macs opens earlier entries and that a successful connection moves that Mac to the top after reopening the menu. Native sessions remain experimental.

Use **Check for Updates…** on each Mac, or download the ZIP. Updates install while idle. Apple silicon; macOS 14 or later. Developer ID signed, notarized and stapled. All builds and tests run on the local Mac; GitHub Actions remains disabled.
