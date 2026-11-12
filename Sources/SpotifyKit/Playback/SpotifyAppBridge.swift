#if os(macOS)
import AppKit
import CoreServices
import Foundation
import OpenMusicCore

/// Controls the Spotify desktop app with raw Apple Events.
///
/// The codes come from Spotify's scripting dictionary (`Spotify.app/Contents/Resources/Spotify.sdef`), so nothing
/// is compiled at runtime and events go out from this actor with a short timeout instead of blocking the main thread.
/// `SpotifyAppBridge.scriptEquivalents` holds the same commands as AppleScript for `openmusic-probe spotify applescript-check`.
public actor SpotifyAppBridge {
    public static let bundleID = "com.spotify.client"

    /// Four-char codes used, keyed by their sdef name. Checked against the installed app's sdef by the probe.
    public static let dictionaryCodes: [(kind: String, name: String, code: String)] = [
        ("command", "play track", "spfyPCtx"),
        ("command", "play", "spfyPlay"),
        ("command", "pause", "spfyPaus"),
        ("property", "current track", "pTrk"),
        ("property", "sound volume", "pVol"),
        ("property", "player state", "pPlS"),
        ("property", "player position", "pPos"),
        ("property", "duration", "pDur"),
        ("property", "id", "ID  "),
        ("enumerator", "stopped", "kPSS"),
        ("enumerator", "playing", "kPSP"),
        ("enumerator", "paused", "kPSp"),
    ]

    /// What each event does, written as AppleScript.
    public static let scriptEquivalents: [String] = [
        #"play track "spotify:track:4uLU6hMCjMI75M1A2tKUQC""#,
        "play",
        "pause",
        "get player state",
        "get player position",
        "set player position to 30",
        "get sound volume",
        "set sound volume to 50",
        "get id of current track",
        "get duration of current track",
    ]

    public enum Permission: String, Sendable {
        case granted, denied, notDetermined, notRunning, unknown
    }

    public init() {}

    // MARK: App lifecycle

    public nonisolated static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public nonisolated static var isInstalled: Bool { appURL != nil }

    public nonisolated static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Starts Spotify without bringing it forward, then waits until it answers Apple Events.
    public func launchIfNeeded() async throws {
        if Self.isRunning { return }
        guard let url = Self.appURL else { throw ProviderError.unplayable("Spotify isn't installed on this Mac.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw ProviderError.unplayable("Couldn't open Spotify: \(error.localizedDescription)")
        }
        // Spotify takes a few seconds to load its player before it handles commands.
        for _ in 0..<40 {
            if (try? state()) != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ProviderError.unplayable("Spotify didn't respond after launching. Is it signed in?")
    }

    /// Automation (TCC) permission for controlling Spotify. `ask` shows the system prompt if it hasn't been answered.
    public func permission(ask: Bool) -> Permission {
        guard Self.isRunning else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }

    // MARK: Commands

    public func playTrack(_ uri: String) throws {
        try send("spfy", "PCtx", direct: NSAppleEventDescriptor(string: uri))
    }

    public func play() throws { try send("spfy", "Play") }
    public func pause() throws { try send("spfy", "Paus") }

    public func state() throws -> RemotePlayerState {
        let value = try get(property("pPlS"))
        switch value?.enumCodeValue {
        case fourCC("kPSP"): return .playing
        case fourCC("kPSp"): return .paused
        default: return .stopped
        }
    }

    public func position() throws -> TimeInterval {
        try get(property("pPos"))?.doubleValue ?? 0
    }

    public func setPosition(_ seconds: TimeInterval) throws {
        try set(property("pPos"), to: NSAppleEventDescriptor(double: max(0, seconds)))
    }

    /// 0...100
    public func volume() throws -> Int {
        Int(try get(property("pVol"))?.int32Value ?? 0)
    }

    public func setVolume(_ percent: Int) throws {
        try set(property("pVol"), to: NSAppleEventDescriptor(int32: Int32(min(100, max(0, percent)))))
    }

    /// `spotify:track:<id>` of the loaded track, nil when nothing is loaded.
    public func currentTrackURI() throws -> String? {
        do {
            guard let id = try get(property("ID  ", of: property("pTrk")))?.stringValue, !id.isEmpty else { return nil }
            return id
        } catch let error as SpotifyAppError where error.isNoSuchObject {
            return nil
        }
    }

    /// Seconds. The sdef reports milliseconds.
    public func currentDuration() throws -> TimeInterval? {
        do {
            guard let ms = try get(property("pDur", of: property("pTrk")))?.int32Value, ms > 0 else { return nil }
            return TimeInterval(ms) / 1000
        } catch let error as SpotifyAppError where error.isNoSuchObject {
            return nil
        }
    }

    public func sample() throws -> RemoteSample {
        let state = try state()
        let uri = try currentTrackURI()
        return RemoteSample(
            state: state,
            trackURI: uri,
            position: try position(),
            duration: uri == nil ? nil : try currentDuration(),
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    // MARK: Apple Event plumbing

    private func property(_ code: String, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("prop")), forKeyword: fourCC("want"))
        record.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: fourCC("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("prop")), forKeyword: fourCC("form"))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(code)), forKeyword: fourCC("seld"))
        return record.coerce(toDescriptorType: fourCC("obj ")) ?? record
    }

    private func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        try send("core", "getd", direct: specifier)
    }

    private func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        try send("core", "setd", direct: specifier, params: [fourCC("data"): value])
    }

    @discardableResult
    private func send(_ eventClass: String, _ eventID: String, direct: NSAppleEventDescriptor? = nil,
                      params: [AEKeyword: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor? {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleID)
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCC(eventClass),
            eventID: fourCC(eventID),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let direct { event.setParam(direct, forKeyword: fourCC("----")) }
        for (key, value) in params { event.setParam(value, forKeyword: key) }

        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 4)
        } catch let error as NSError {
            throw SpotifyAppError(code: error.code)
        }
        if let errorNumber = reply.paramDescriptor(forKeyword: fourCC("errn"))?.int32Value, errorNumber != 0 {
            throw SpotifyAppError(code: Int(errorNumber))
        }
        return reply.paramDescriptor(forKeyword: fourCC("----"))
    }
}

/// An Apple Event failure, with the cases OpenMusic explains to the listener.
public struct SpotifyAppError: LocalizedError, Sendable, Hashable {
    public var code: Int

    public var isPermissionDenied: Bool { code == Int(errAEEventNotPermitted) || code == Int(errAEEventWouldRequireUserConsent) }
    public var isNotRunning: Bool { code == Int(procNotFound) || code == Int(connectionInvalid) }
    /// -1728 errAENoSuchObject, -1719 errAEIllegalIndex: no current track.
    public var isNoSuchObject: Bool { code == -1728 || code == -1719 }

    public var errorDescription: String? {
        if isPermissionDenied {
            return "\(ProductInfo.name) isn't allowed to control Spotify. Turn on Spotify for \(ProductInfo.name) in System Settings → Privacy & Security → Automation."
        }
        if isNotRunning { return "Spotify isn't running." }
        if code == Int(errAETimeout) { return "Spotify didn't respond in time." }
        return "Spotify returned error \(code)."
    }
}

/// "spfy" → 'spfy'
func fourCC(_ string: String) -> FourCharCode {
    string.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}

#else
import Foundation
import OpenMusicCore

// iOS has no Apple Events and no Spotify desktop app to drive: the bridge reports the app as missing, so the
// engine always picks Spotify Connect. Same API as the macOS bridge so the routes compile unchanged.

let errAEEventNotPermitted = -1743
let errAEEventWouldRequireUserConsent = -1744

public actor SpotifyAppBridge {
    public static let bundleID = "com.spotify.client"
    public enum Permission: String, Sendable { case granted, denied, notDetermined, notRunning, unknown }

    public init() {}

    public nonisolated static var appURL: URL? { nil }
    public nonisolated static var isInstalled: Bool { false }
    public nonisolated static var isRunning: Bool { false }

    private static var unavailable: ProviderError { .unplayable("Spotify plays on iPhone through Spotify Connect.") }

    public func launchIfNeeded() async throws { throw Self.unavailable }
    public func permission(ask: Bool) -> Permission { .notRunning }
    public func playTrack(_ uri: String) throws { throw Self.unavailable }
    public func play() throws { throw Self.unavailable }
    public func pause() throws { throw Self.unavailable }
    public func setPosition(_ seconds: TimeInterval) throws { throw Self.unavailable }
    public func setVolume(_ percent: Int) throws { throw Self.unavailable }
    public func sample() throws -> RemoteSample { throw Self.unavailable }
}

public struct SpotifyAppError: LocalizedError, Sendable, Hashable {
    public var code: Int
    public var isPermissionDenied: Bool { code == errAEEventNotPermitted || code == errAEEventWouldRequireUserConsent }
    public var isNotRunning: Bool { true }
    public var isNoSuchObject: Bool { code == -1728 || code == -1719 }
    public var errorDescription: String? { "The Spotify app can't be controlled on iPhone." }
}
#endif
