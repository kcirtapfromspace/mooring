// Standalone tests: compile this file together with app/AppleSession.swift.
// No Accessibility calls, permission changes, or real session operations occur.
import Foundation
import Darwin

struct SavedMac { let host: String; let port: UInt16 }

@main
struct AppleSessionTests {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        checks += 1
        if !(try condition()) { throw Failure(message: label) }
    }
    static func plist(_ url: String, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["URL": url], format: format, options: 0)
    }
    static func parse(_ url: String) throws -> AppleSessionDocument? {
        AppleSessionDocument.parse(try plist(url))
    }
    static func main() {
        do { try run() }
        catch let error as Failure { fputs("AppleSession test failed: \(error.message)\n", stderr); exit(1) }
        catch { fputs("AppleSession test fixture failed.\n", stderr); exit(1) }
    }
    static func run() throws {
        try expect(AppleSessionDocument.canonicalHost("Mac.Example.") == "mac.example", "DNS canonicalization")
        try expect(AppleSessionDocument.canonicalHost("192.168.1.2") == "192.168.1.2", "IPv4")
        try expect(AppleSessionDocument.canonicalHost("[2001:0DB8:0:0::1]") == "2001:db8::1", "bracketed IPv6")
        try expect(AppleSessionDocument.canonicalHost("2001:DB8::1") == "2001:db8::1", "bare IPv6")
        for invalid in ["", "-host", "host-", "host..local", "host..", "127.01.0.1", "127.1", "999.1.1.1", "0x7f000001", "0x7f.0.0.1", "[host]", "[::1", "::1]", "fe80::1%en0", "host name", "host\t", "host\n", "host/path", "user@host", "host?x", "☃.local", "127.0.0.1\0evil", "::1\0evil", String(repeating: "x", count: 64) + ".local"] {
            try expect(AppleSessionDocument.canonicalHost(invalid) == nil, "invalid host fixture: " + String(reflecting: invalid))
        }
        let high = try parse("vnc://Mac.Example.:5901/?quality=high&numVirtualDisplays=1")
        try expect(high == AppleSessionDocument(host: "mac.example", port: 5901, mode: "high_performance"), "high mode")
        for quality in ["adaptive", "full"] {
            let standard = try parse("vnc://mac.local/?quality=\(quality)&numVirtualDisplays=0")
            try expect(standard == AppleSessionDocument(host: "mac.local", port: 5900, mode: "standard"), "standard mode")
        }
        try expect(try parse("vnc://%4Dac.local/?quality=high&numVirtualDisplays=1")?.host == "mac.local", "percent-encoded DNS")
        try expect(try parse("vnc://[2001:0DB8::1]:5999/?quality=high&numVirtualDisplays=1")?.host == "2001:db8::1", "IPv6 URL")
        try expect(try parse("vnc://%5B2001%3Adb8%3A%3A1%5D/?quality=high&numVirtualDisplays=1")?.host == "2001:db8::1", "percent-encoded IPv6 URL")
        try expect(try parse("vnc://[::ffff:192.0.2.1]/?quality=adaptive&numVirtualDisplays=0")?.host == "::ffff:192.0.2.1", "mapped IPv6 URL")
        let binary = try plist("vnc://mac.local/?quality=high&numVirtualDisplays=1", format: .binary)
        try expect(AppleSessionDocument.parse(binary)?.mode == "high_performance", "binary plist")
        // Unknown or conflicting mode keeps the endpoint visible for ambiguity
        // detection; it must never authorize a session action.
        for query in ["", "quality=high", "numVirtualDisplays=1", "quality=high&numVirtualDisplays=2", "quality=adaptive&numVirtualDisplays=1", "quality=high&numVirtualDisplays=0", "quality=high&numVirtualDisplays=1&quality=adaptive", "quality=high&numVirtualDisplays=1&numVirtualDisplays=1", "quality=HIGH&numVirtualDisplays=1", "quality=high&numVirtualDisplays=01", "quality=high&numVirtualDisplays=-1"] {
            let unknown = try parse("vnc://mac.local/?\(query)")
            try expect(unknown?.host == "mac.local" && unknown?.mode == nil, "unconfirmed mode")
        }
        for invalid in ["https://mac.local/", "vnc://mac.local:0/", "vnc://mac.local:65536/", "vnc://mac.local:99999999999999999999999999999/", "vnc://mac.local:/", "vnc://mac.local/path", "vnc://mac.local/#fragment", "vnc://mac.local%00.evil/", "vnc://127.0.0.1%00evil/", "vnc://mac%252elocal/", "vnc://mac.local%2fevil/", "vnc:///", "vnc://[fe80::1%25en0]/"] {
            try expect(try parse(invalid) == nil, "invalid document URL")
        }
        let missingURL = try PropertyListSerialization.data(fromPropertyList: ["name": "test"], format: .xml, options: 0)
        let wrongURL = try PropertyListSerialization.data(fromPropertyList: ["URL": 4], format: .xml, options: 0)
        try expect(AppleSessionDocument.parse(missingURL) == nil, "missing URL")
        try expect(AppleSessionDocument.parse(wrongURL) == nil, "wrong URL type")
        try expect(AppleSessionDocument.parse(Data("invalid".utf8)) == nil, "invalid plist")
        try expect(AppleSessionDocument.parse(Data(repeating: 32, count: 65_537)) == nil, "oversized data")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maclink-session-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("test.vncloc")
        try binary.write(to: valid)
        try expect(AppleSessionDocument.read(document: valid.absoluteString)?.mode == "high_performance", "bounded file read")
        let link = directory.appendingPathComponent("link.vncloc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        try expect(AppleSessionDocument.read(document: link.absoluteString) == nil, "symlink rejected")
        let large = directory.appendingPathComponent("large.vncloc")
        try Data(repeating: 32, count: 65_537).write(to: large)
        try expect(AppleSessionDocument.read(document: large.absoluteString) == nil, "oversized file")
        let folder = directory.appendingPathComponent("directory.vncloc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try expect(AppleSessionDocument.read(document: folder.absoluteString) == nil, "directory rejected")
        let fifo = directory.appendingPathComponent("fifo.vncloc")
        guard mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0 else { throw Failure(message: "create FIFO fixture") }
        try expect(AppleSessionDocument.read(document: fifo.absoluteString) == nil, "FIFO rejected without blocking")
        try expect(AppleSessionDocument.read(document: "file://remote.example/test.vncloc") == nil, "remote file authority rejected")
        try expect(AppleSessionDocument.read(document: "https://example.com/test.vncloc") == nil, "non-file document rejected")
        try expect(AppleSessionDocument.read(document: valid.absoluteString + "?quality=high") == nil, "file query rejected")
        try expect(AppleSessionDocument.read(document: valid.absoluteString + "%00extra.vncloc") == nil, "file NUL rejected")
        print("AppleSession: \(checks) parser and bounded-reader checks passed; no Accessibility actions performed.")
    }
}
