import Foundation

/// Writes the sync self-test log (`synctest.log` in `-OpenMusicSyncDir`). Only ever created by `SyncSelfTest` (Debug
/// builds); it compiles in Release only because `SyncHub.log` is read in both, and is always nil there.
@MainActor
final class SyncTestLog {
    let directory: URL
    var url: URL { directory.appendingPathComponent("synctest.log") }
    private let started = Date()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    func write(_ line: String) {
        let stamped = String(format: "[+%8.3fs] ", Date().timeIntervalSince(started)) + "\(Self.wall()) " + line
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((stamped + "\n").utf8))
        try? handle.close()
    }

    /// Wall-clock time to the millisecond, so the Mac's and the iPhone's logs line up.
    static func wall() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
