import OpenMusicCore
import SwiftUI

/// YouTube Music's sections in Settings > Accounts. The Accounts pane shows the account row and owns
/// Sign In / Sign Out, so this adds only plain `Section`s to its form: the cookie fallback, behind Advanced.
/// Stream quality lives in Settings › Playback.
struct YTMSettingsView: View {
    let provider: YouTubeMusicProvider
    @State private var cookieHeader = ""
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        // Normal sign-in comes first, in the account row above. Manual cookie import is for people who
        // need it, so it waits behind an Advanced disclosure.
        Section {
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(provider.authStatus.isSignedIn ? "Replace with a browser cookie" : "Sign in with a browser cookie")
                        .font(.headline)
                    Text("In a browser signed in to music.youtube.com, open the developer tools, copy the Cookie request header from any request to music.youtube.com, and paste it here. It's stored only in your Keychain.")
                        .font(.callout)
                        .foregroundStyle(.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $cookieHeader)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 70)
                    HStack {
                        if let message { Text(message).font(.callout).foregroundStyle(.readableSecondary) }
                        Spacer()
                        Button("Use Cookie") { useCookie() }
                            .disabled(cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    }
                }
                .padding(.top, 4)
            }
        } header: {
            ProviderSettingsHeader()
        }
    }

    private func useCookie() {
        isWorking = true
        message = nil
        let header = cookieHeader
        Task {
            do {
                try await provider.signIn(cookieHeader: header)
                cookieHeader = ""
                message = "Signed in."
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }
}
