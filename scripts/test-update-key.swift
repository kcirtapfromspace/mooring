// An ephemeral, independently generated test key. Never reads or exports a
// production Keychain item. Its private seed is removed by the test's EXIT trap.
import CryptoKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let key = Curve25519.Signing.PrivateKey()
let seed = directory.appendingPathComponent("seed")
try key.rawRepresentation.base64EncodedData().write(to: seed)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seed.path)
try key.publicKey.rawRepresentation.base64EncodedData().write(to: directory.appendingPathComponent("public"))
