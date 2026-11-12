import AppKit

// Debug builds only: Release builds have no self-test entry points.
#if DEBUG
/// `OPENMUSIC_SELFTEST=menus OPENMUSIC_SELFTEST_OUT=<file>` (mock or real): writes the main menu, one item per line with
/// its shortcut and whether it is enabled, so shortcuts can be reviewed without opening the menus. Then quits.
@MainActor
struct MenuSelfTest {
    let output: URL

    func run() async {
        // Let SwiftUI build the commands.
        try? await Task.sleep(for: .seconds(1.5))
        var lines: [String] = []
        func walk(_ menu: NSMenu, depth: Int) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                var key = ""
                if !item.keyEquivalent.isEmpty {
                    let m = item.keyEquivalentModifierMask
                    key = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "")
                        + (m.contains(.command) ? "⌘" : "") + Self.name(item.keyEquivalent)
                }
                let indent = String(repeating: "  ", count: depth)
                lines.append("\(indent)\(item.title)\(key.isEmpty ? "" : "  \(key)")\(item.isEnabled ? "" : "  (disabled)")")
                if let sub = item.submenu, depth < 2 { walk(sub, depth: depth + 1) }
            }
        }
        if let main = NSApp.mainMenu { walk(main, depth: 0) }
        try? lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func name(_ key: String) -> String {
        switch key.unicodeScalars.first.map({ Int($0.value) }) {
        case NSRightArrowFunctionKey: "→"
        case NSLeftArrowFunctionKey: "←"
        case NSUpArrowFunctionKey: "↑"
        case NSDownArrowFunctionKey: "↓"
        case 0x1b: "Esc"
        case 0x20: "Space"
        default: key.uppercased()
        }
    }
}
#endif
