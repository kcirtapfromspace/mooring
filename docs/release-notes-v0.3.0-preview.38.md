# Mooring 0.3.0 preview 38 — No route like home

Record a demo without showing your Macs' names or network addresses. Turn on **Settings → General → Hide computer information for demos** to use anonymous Mac names, `mac-1.no-route-home.invalid`, “NXDOMAIN sweet NXDOMAIN,” and reserved example addresses, including `2001:db8::dead:beef`. The preference persists and updates Mooring windows, menus and tooltips immediately. Connections still use their saved endpoints. Remote desktop content and Apple's Screen Sharing windows are outside this view preference.

With demo privacy off, Connections and Settings → Viewing list every saved address for a paired Mac, with readable address scopes and the last connected address first. General settings show this Mac's Bonjour hostname and assigned IPv4 and IPv6 addresses by interface, including tunnels, loopback, link-local and inactive interfaces. Remote address lists contain the addresses learned when pairing, rather than a live discovery scan.

Either Mac can remove a pairing. Connected Macs running this preview exchange an authenticated revocation notice, end the session and require a fresh pairing code. Revocation survives restart and leaves other approved connections intact. Offline removal erases the local credential immediately; it cannot update an unreachable Mac's Allowed Macs list. New pairings use a separate device key for each sharing Mac; existing pairings retain their keys until paired again.

Removing an older pairing could fail with Keychain ownership error `-25244` and incorrectly suggest unlocking the Mac. Mooring now erases the complete credential and its key without changing the item's ownership when deletion is refused. If erasure also fails, it reports the error and keeps the saved row for retry. Existing-item updates change only the credential data.

Local validation covers Rust, mocked Keychain deletion/erasure failures, revocation and fresh pairing over encrypted loopback, preservation of other approved keys, native media and input, the packaged CLI, and the app build. The native UI was checked with synthetic Macs and isolated preferences. Real two-Mac sessions and the affected Mac's Keychain ACL remain separate acceptance checks; update both Macs to test revocation notices.

Use **Check for Updates…** on each Mac, or download the ZIP. Updates install while idle. Apple silicon and macOS 14 or later; Developer ID signed, notarized and stapled. All tests, builds, signing and packaging run on the local Mac. GitHub Actions remains disabled.
