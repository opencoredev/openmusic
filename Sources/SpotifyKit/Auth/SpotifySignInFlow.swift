#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AuthenticationServices
import Foundation
import MedleyCore

/// Runs the browser part of sign-in and returns the redirect carrying the authorization code.
@MainActor
final class SpotifySignInFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var receiver: LoopbackReceiver?
    #if os(macOS)
    /// Opens the authorize URL. The default browser in the app; the probe can print it instead.
    var openURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Brings Medley back in front of the browser once Spotify redirects.
    var activateApp: @MainActor () -> Void = { NSApp?.activate() }
    #else
    /// On iOS the authorize page opens in an in-app `ASWebAuthenticationSession` sheet; its redirect to
    /// 127.0.0.1 reaches the loopback listener in this (foreground) app, which then closes the sheet.
    /// Set to a closure to open the URL some other way instead (tests).
    var openURL: (@MainActor (URL) -> Bool)?
    var activateApp: @MainActor () -> Void = {}
    #endif

    /// Opens Spotify's consent page for the URL `makeURL` builds from the final redirect URI, and waits for the redirect.
    func authorize(target: SpotifyRedirectTarget, makeURL: @MainActor (String) -> URL) async throws -> SpotifyAuthorization {
        switch target {
        case .loopback(let port, let path, let portIsFlexible):
            return try await loopback(port: port, path: path, portIsFlexible: portIsFlexible, makeURL: makeURL)
        case .customScheme:
            let uri = SpotifyRedirect.customScheme.uri
            return SpotifyAuthorization(callback: try await webAuthenticationSession(makeURL(uri)), redirectURI: uri)
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        receiver?.cancel()
        receiver = nil
    }

    /// Default browser + one-shot listener on 127.0.0.1. Uses the browser where the listener is already signed in to Spotify.
    private func loopback(port: UInt16, path: String, portIsFlexible: Bool, makeURL: @MainActor (String) -> URL) async throws -> SpotifyAuthorization {
        var receiver = LoopbackReceiver(port: port, path: path)
        self.receiver = receiver
        defer { self.receiver = nil }
        let bound: UInt16
        do {
            bound = try await receiver.start()
        } catch SpotifyAuthError.portInUse where portIsFlexible && port != 0 {
            // The built-in client takes any loopback port, so let the system pick a free one.
            receiver = LoopbackReceiver(port: 0, path: path)
            self.receiver = receiver
            bound = try await receiver.start()
        }
        // Cancelled while the port was binding: don't send the listener to the browser.
        if Task.isCancelled {
            receiver.cancel()
            throw SpotifyAuthError.cancelled
        }
        let redirectURI = "http://127.0.0.1:\(bound)\(path)"
        #if os(macOS)
        guard openURL(makeURL(redirectURI)) else {
            receiver.cancel()
            throw SpotifyAuthError.authorization("couldn't open your browser")
        }
        #else
        if let openURL {
            guard openURL(makeURL(redirectURI)) else {
                receiver.cancel()
                throw SpotifyAuthError.authorization("couldn't open the sign-in page")
            }
        } else {
            openSheet(makeURL(redirectURI), whileWaitingOn: receiver)
        }
        defer { session?.cancel(); session = nil }
        #endif
        let callback = try await receiver.waitForRedirect()
        activateApp()
        return SpotifyAuthorization(callback: callback, redirectURI: redirectURI)
    }

    /// In-app sheet that catches `openmusic://spotify-callback`.
    private func webAuthenticationSession(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(ProductInfo.urlScheme)) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                } else {
                    continuation.resume(throwing: SpotifyAuthError.authorization(error?.localizedDescription ?? "no response"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            // Cancelled before the sheet opened (`cancel()` had nothing to close yet): don't open it.
            if Task.isCancelled {
                continuation.resume(throwing: SpotifyAuthError.cancelled)
                return
            }
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: SpotifyAuthError.authorization("couldn't start the sign-in sheet"))
            }
        }
    }

    #if os(iOS)
    /// Shows Spotify's consent page in the system sign-in sheet. The redirect never matches the sheet's own
    /// callback scheme; the loopback listener catches it. Closing the sheet cancels the listener.
    private func openSheet(_ url: URL, whileWaitingOn receiver: LoopbackReceiver) {
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(ProductInfo.urlScheme)) { _, error in
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                receiver.cancel()
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            self.session = nil
            receiver.cancel()
        }
    }
    #endif

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// Sign-in with the built-in client outside the app, for `medley-probe spotify login`: binds the listener, hands the
/// authorize URL to `open` (print it, or open a browser), waits for the redirect, and exchanges the code.
public enum SpotifyLoginCheck {
    @MainActor
    public static func run(
        open: @escaping @MainActor (URL) -> Bool,
        transport: any SpotifyTransport = URLSessionTransport()
    ) async throws -> SpotifyToken {
        let pkce = PKCE()
        let state = PKCE.randomState()
        let flow = SpotifySignInFlow()
        flow.openURL = open
        flow.activateApp = {}
        let response = try await flow.authorize(target: .builtIn) { redirectURI in
            SpotifyAuthConfig(clientID: SpotifyBuiltInClient.clientID, redirectURI: redirectURI).authorizeURL(pkce: pkce, state: state)
        }
        let code = try SpotifyAuthConfig.code(fromRedirect: response.callback, expectedState: state)
        let config = SpotifyAuthConfig(clientID: SpotifyBuiltInClient.clientID, redirectURI: response.redirectURI)
        return try await SpotifyAuthService(transport: transport).exchange(code: code, verifier: pkce.verifier, config: config)
    }
}
