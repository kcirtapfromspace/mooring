# Mooring 0.3.0 preview 31 — Branding and native UX

Mooring has a cobalt geometric connection icon and a more consistent native interface. It now appears in the Dock and Cmd+Tab, as well as the menu bar. Closing its windows keeps the app running; the Dock and Open Connections bring its window back. Existing connections, pairings, and preferences are preserved.

## Interface changes

- Connections puts Pair a Mac and Share this Mac within reach, with separate guidance for Mooring pairing and Apple Screen Sharing.
- Pairing, sharing, session-control permission, and settings windows use consistent branding and spacing. Sharing and Settings scroll when their content grows.
- Settings has Sharing, Viewing, and General categories. General opens the existing Apple Screen Sharing automation settings.
- Pairing requires a nonempty code before connecting; address overrides stay behind a disclosure control. Invalid input remains visible in the form.
- Standard Hide, Window, and Dock menus are available. Open Connections restores a minimized window, and a Dock reopen leaves an already visible session available.
- The Apple Screen Sharing menu selects the intended saved Mac when Mooring pairings also appear in the list.

## Validation and testing

Validation runs on the local development Mac: the complete local CI suite, Rust and native session checks, hardware media tests, the encrypted loopback stream, and the arm64 macOS 14 app build. UI checks use isolated connection stores and preferences; the connection forms, inline errors, settings categories, and light/dark layouts were inspected. The cobalt icon and buttons were checked in the running app; white button text has 6.87:1 contrast on the cobalt fill.

Test the new Dock and Cmd+Tab behavior on both Macs, including closing and reopening Connections and returning to a live viewer. While controlling a remote Mac, captured system shortcuts still go to the remote Mac as before. Confirm both connection types select the correct Mac from the menu bar.

Native sessions remain experimental. Local and loopback checks do not establish real two-Mac video negotiation, mode switching, or wake behavior. Those checks remain separate release acceptance gates; see [TESTING.md](TESTING.md) and the previous preview's wake-recovery notes.

Use Check for Updates on each Mac, or download the ZIP from this release. Automatic updates install while no session is connected. Apple silicon and macOS 14 or later; Developer ID signed, notarized, and stapled. GitHub Actions stays disabled.
