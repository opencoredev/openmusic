#if DEBUG
import Foundation
import Testing
@testable import OpenMusicCore

/// The debug self-test's stand-in for the Keychain (`Keychain.isolate(in:)`).
@Suite struct FileKeychainTests {
    @Test func storesReadsAndDeletesInPrivateFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openmusic-file-keychain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileKeychain(directory: dir)
        #expect(store.name == "file \(dir.path)")
        #expect(store.data(for: "spotify.token") == nil)

        try store.set(Data("secret".utf8), for: "spotify.token")
        #expect(store.data(for: "spotify.token") == Data("secret".utf8))
        let file = dir.appendingPathComponent("spotify.token")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(dirPerms == 0o700)

        try store.set(nil, for: "spotify.token")
        #expect(store.data(for: "spotify.token") == nil)
        try store.set(nil, for: "spotify.token")  // deleting nothing is fine
    }

    @Test func accountNamesStayInsideTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openmusic-file-keychain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileKeychain(directory: dir)
        try store.set(Data("x".utf8), for: "../escape")
        #expect(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape").path) == false)
        #expect(store.data(for: "../escape") == Data("x".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }
}
#endif
