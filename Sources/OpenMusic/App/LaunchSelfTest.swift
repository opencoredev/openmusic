import AppKit
import SwiftUI

// Debug builds only: Release builds have no self-test entry points.
#if DEBUG
/// `OPENMUSIC_SELFTEST=launch OPENMUSIC_SELFTEST_OUT=<file>` (mock or real): how long from the process starting until the
/// main window is on screen, and until Home has content instead of its placeholder. Writes one line and quits.
@MainActor
struct LaunchSelfTest {
    let model: AppModel
    let output: URL

    func run() async {
        let start = Self.processStart()
        while model.mainWindow?.isVisible != true { try? await Task.sleep(for: .milliseconds(5)) }
        let window = Date().timeIntervalSince(start)
        // Home's content is cached in `PageCache` once its load finishes.
        var waited = 0
        while !model.cache.hasEntry(prefix: "home:"), waited < 3000 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        let home = Date().timeIntervalSince(start)
        let line = String(format: "launch: window visible %.0f ms, Home content %.0f ms after the process started (mock %@)",
                          window * 1000, home * 1000, model.isMock ? "yes" : "no")
        try? (line + "\n").write(to: output, atomically: true, encoding: .utf8)
        exit(0)
    }

    /// When the kernel started this process.
    private static func processStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }
}
#endif
