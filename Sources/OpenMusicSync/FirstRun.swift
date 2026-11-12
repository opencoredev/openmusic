import Foundation
import OpenMusicCore

/// The first-run flow (docs/onboarding.md): Welcome, Your music, Sync, Approve this device, Done. Both apps show it
/// once; finishing or skipping it is final, and a version bump doesn't bring it back.
///
/// The decision is local and made at launch, before any network: a fresh install shows it, an install that already
/// answered the old welcome sheets (`didShowAccountWelcome`, `didOnboard`) or restored a service sign-in doesn't.
public enum FirstRun {
    /// UserDefaults: the flow was finished or skipped.
    public static let finishedKey = "firstRunFinished"
    /// The keys earlier builds set once their welcome sheets were answered. Either one means this isn't a first run.
    public static let legacyKeys = ["didShowAccountWelcome", "didOnboard"]

    /// Whether to show the flow at this launch. `anyServiceSignedIn`: a YouTube Music or Spotify sign-in was restored
    /// (an install that has been used, or an iPhone reinstall whose Keychain survived).
    public static func shouldShow(defaults: UserDefaults = .standard, anyServiceSignedIn: Bool) -> Bool {
        if defaults.bool(forKey: finishedKey) { return false }
        if legacyKeys.contains(where: { defaults.bool(forKey: $0) }) { return false }
        return !anyServiceSignedIn
    }

    /// The launch's decision, remembered: an install that already has a service sign-in (an iPhone reinstall whose
    /// Keychain survived) is marked finished, so signing out of that service later doesn't bring the flow back.
    public static func showAtLaunch(defaults: UserDefaults = .standard, anyServiceSignedIn: Bool) -> Bool {
        let show = shouldShow(defaults: defaults, anyServiceSignedIn: anyServiceSignedIn)
        if !show, anyServiceSignedIn, !defaults.bool(forKey: finishedKey) { markFinished(defaults: defaults) }
        return show
    }

    /// Finished or skipped: never shown again by itself (Settings can still open it).
    public static func markFinished(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: finishedKey)
        // The old welcome sheets read these; an older build run after this one must not show them either.
        for key in legacyKeys { defaults.set(true, forKey: key) }
    }

    public enum Step: String, Hashable, Sendable, CaseIterable {
        case welcome, music, sync, server, approve
    }

    /// Where the flow goes once the account is signed in and sync answered: Approve this device while the account
    /// has another device holding the key and this one doesn't, else Done. `nil` while it is still finding out
    /// (`none`: registration or the key request hasn't settled yet).
    public enum AfterSignIn: Equatable, Sendable { case approve, done }

    public static func afterSignIn(keyStatus: SyncService.KeyStatus) -> AfterSignIn? {
        switch keyStatus {
        case .none: nil
        case .available: .done
        // The account already has a device with the key: this one asks it.
        case .waiting, .comparing, .denied, .failed, .outdated: .approve
        // A key that isn't the account's can't be fixed by approving; Settings › Account explains it.
        case .mismatch: .done
        }
    }

    /// "your Mac", "your iPhone": the device to open, for "Open OpenMusic on your Mac to approve this iPhone".
    public static func deviceNoun(_ platform: DevicePlatform?) -> String {
        switch platform {
        case .mac: "your Mac"
        case .ios: "your iPhone"
        case .windows: "your PC"
        case .android, .linux, .unknown, nil: "your other device"
        }
    }

    /// The headline of Approve this device. `holders`: the account's devices that have the key.
    public static func approveTitle(holders: [SyncDevice], here: String) -> String {
        let platforms = Set(holders.map(\.platform))
        let noun = platforms.count == 1 ? deviceNoun(platforms.first) : deviceNoun(nil)
        return "Open \(ProductInfo.name) on \(noun) to approve \(here)"
    }

    /// What a failed code check says in the flow: Clerk's short answers ("Incorrect code") said with what to do next.
    public static func codeProblem(_ error: any Error) -> String {
        if case ClerkError.refused(let code, _)? = error as? ClerkError {
            switch code {
            case "form_code_incorrect":
                return "That code isn't right. Check the newest email from \(ProductInfo.name) and try again, or send a new code."
            case "verification_expired":
                return "That code has expired. Send a new code."
            case "verification_failed", "too_many_requests":
                return "Too many tries. Wait a minute, then send a new code."
            default: break
            }
        }
        return error.localizedDescription
    }

    /// "Set up an OpenMusic server": the self-hosting guide (docs/self-hosting.md) in four steps, the same on every
    /// platform. Each is a title and one or two sentences.
    public static let serverSetupSteps: [(title: String, detail: String)] = [
        ("Make a Clerk app", "Free at clerk.com. Turn on email code sign-in and the Native API, allow openmusic://oauth-callback, and add a JWT template named “convex”."),
        ("Start the server", "In the \(ProductInfo.name) source, open sync/self-host, put your Clerk keys in .env and run ./deploy.sh. It needs Docker or Podman."),
        ("Give it an HTTPS address", "Tailscale Serve is the easiest: only your own devices can reach it. A domain with a reverse proxy works too."),
        ("Enter the address here", "deploy.sh ends with the address to paste. Check it here, then sign in with the same email on each device."),
    ]
    public static let serverSetupFooter = "Details, troubleshooting and upgrades are in the self-hosting guide that comes with the server. Your server stores no names or email addresses, and never the key to what you play."

    /// The holder's prompt when `device` asks for the key: a short question and what to check.
    public static func allowTitle(_ device: String) -> String { "Allow \(device)?" }
    public static func allowMessage(_ device: String) -> String {
        "\(device) wants to use your YouTube Music and Spotify sign-ins. Allow only if it shows this same code. Your sign-ins stay end-to-end encrypted between your devices."
    }

    /// The email code's resend wait.
    public static let resendDelay: Duration = .seconds(30)

    /// The digits of a pasted or typed code, at most six ("123 456", "123-456" and "Code: 123456" all work).
    public static func codeDigits(_ text: String) -> String {
        String(text.filter(\.isASCII).filter(\.isNumber).prefix(6))
    }

    /// "123 456" for reading a code off another screen.
    public static func spacedCode(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    /// The code read digit by digit ("4 8 2, 9 1 3"), for VoiceOver.
    public static func spokenCode(_ code: String) -> String {
        let digits = Array(code.filter(\.isNumber)).map(String.init)
        guard digits.count == 6 else { return code }
        return digits[0..<3].joined(separator: " ") + ", " + digits[3..<6].joined(separator: " ")
    }
}
