import Foundation
import MedleyCore
import Testing
@testable import YouTubeMusicKit

/// A playlist write goes out only with the credentials of the account the app checked (Sol's review of 48d0809): the
/// client checks the binding where it picks the request's cookies.
@Suite struct YouTubeWriteBindingTests {
    private func creds(_ channel: String) -> YTMCredentials {
        YTMCredentials(cookies: ["SAPISID": "x", "SID": "y"], authUser: 0, datasyncId: "\(channel)||session")
    }

    @Test func aWriteIsBoundToTheAccountItWasCheckedFor() async throws {
        let a = creds("A")
        let client = InnerTubeClient(credentials: a)
        let asA = YTMWriteBinding(accountID: YouTubeMusicProvider.accountID(a), epoch: 0)
        try await client.checkWriteBinding(asA)
        // B's cookies land on the client before the request goes.
        _ = try await client.commit(creds("B"), persist: false, store: false, epoch: 1)
        await #expect(throws: PlaylistEditError.accountChanged) { try await client.checkWriteBinding(asA) }
        // A's cookies again under a newer swap (a sign-in synced from another device): the same account still writes.
        _ = try await client.commit(creds("A"), persist: false, store: false, epoch: 2)
        try await client.checkWriteBinding(asA)
    }

    /// Without an account id only the credential swap the app checked counts.
    @Test func withoutAnAccountIDTheSwapMustBeTheSame() async throws {
        let plain = YTMCredentials(cookies: ["SAPISID": "x", "SID": "y"])
        let client = InnerTubeClient()
        _ = try await client.commit(plain, persist: false, store: false, epoch: 1)
        try await client.checkWriteBinding(YTMWriteBinding(accountID: nil, epoch: 1))
        _ = try await client.commit(plain, persist: false, store: false, epoch: 2)
        await #expect(throws: PlaylistEditError.accountChanged) { try await client.checkWriteBinding(YTMWriteBinding(accountID: nil, epoch: 1)) }
    }
}
