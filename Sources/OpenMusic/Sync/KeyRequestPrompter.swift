import SwiftUI
import AppKit
import OpenMusicSync
import Observation

/// Mac: the "Allow <device> to use your YouTube Music and Spotify sign-ins?" alert, an `NSAlert` sheet on the main
/// window that this hub-owned prompter runs, rather than SwiftUI's `.alert`.
///
/// SwiftUI's alert had two bad endings. Read live, it closed itself when its request went away (allowed or withdrawn
/// elsewhere, the device asking again), and it did so in the middle of a layout pass, where AppKit crashed
/// (`NSSheetMoveHelper closeSheet` under `AppKitDialogBridge.updateExistingPresentation`, live run of 2026-11-06).
/// Held in view state instead, it outlived its request: a stale Don't Allow could answer a newer exchange, a
/// replacement request waited unseen behind it, and it survived sign-out and a server switch.
///
/// Here the sheet shows one request of this hub. It is ended from a main-queue turn of its own (never inside SwiftUI's
/// update) as soon as that request is no longer one this hub would show, and when the hub stops. A button acts only if
/// its request is still current (the service checks the exchange again, `denyKey`/`allowKey`), and after every close
/// the next request, if any, comes up.
@MainActor
final class KeyRequestPrompter {
    private weak var hub: SyncHub?
    private var alert: NSAlert?
    private var shown: SyncService.KeyRequest?
    /// The sheet's end was asked for and its completion hasn't run yet.
    private var closing = false
    private var stopped = false
    /// One observation of the hub's pending request is armed at a time.
    private var armed = false
    private var retry: Task<Void, Never>?

    init(hub: SyncHub) {
        self.hub = hub
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    /// The hub stopped (sign-out of the server, a server switch): close what it showed and show nothing more.
    func stop() {
        stopped = true
        retry?.cancel()
        close()
    }

    /// The request on screen, for tests and the self-test.
    var current: SyncService.KeyRequest? { shown }

    /// Arms the observation if none is armed, then reconciles.
    private func update() {
        guard !stopped, let hub else { return }
        if !armed {
            armed = true
            withObservationTracking { _ = hub.pendingKeyRequest } onChange: { [weak self] in
                // Never inside the update that changed it.
                DispatchQueue.main.async {
                    self?.armed = false
                    self?.update()
                }
            }
        }
        reconcile(hub)
    }

    private func reconcile(_ hub: SyncHub) {
        if let shown {
            // Still the same exchange of a request this hub shows: leave it up.
            if hub.service.keyRequests.contains(where: { $0.id == shown.id && $0.commitment == shown.commitment }),
               !hub.dismissedKeyRequests.contains(shown) { return }
            close()
            return
        }
        guard let pending = hub.pendingKeyRequest else { return }
        // Only on a main window that is on screen with no other sheet: a sheet begun behind another is queued by
        // AppKit, where it can't be ended, and would come up later for a request that may be long gone.
        guard let window = hub.model?.mainWindow, window.isVisible, window.attachedSheet == nil else {
            scheduleRetry()
            return
        }
        present(pending, on: window)
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.retry = nil
            self?.update()
        }
    }

    private func present(_ request: SyncService.KeyRequest, on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = FirstRun.allowTitle(request.device.name)
        alert.informativeText = FirstRun.allowMessage(request.device.name)
        // The code to compare, large, between the question and the buttons.
        let code = NSHostingView(rootView: KeyCodeAccessory(code: request.code))
        code.frame = NSRect(origin: .zero, size: code.fittingSize)
        alert.accessoryView = code
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow").keyEquivalent = "\u{1b}"
        self.alert = alert
        shown = request
        closing = false
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { self?.finished(request, response: response) }
        }
    }

    private func finished(_ request: SyncService.KeyRequest, response: NSApplication.ModalResponse) {
        alert = nil
        shown = nil
        closing = false
        if !stopped, let hub, response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
            // Answered: this exchange doesn't come back while its answer is on the way (or if it fails).
            hub.dismissedKeyRequests.dismiss(request)
            if response == .alertFirstButtonReturn {
                Task { await hub.allowKey(request) }
            } else {
                Task { await hub.denyKey(request) }
            }
        }
        // The next request, if one is waiting.
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    /// Ends the sheet from its own main-queue turn, outside any SwiftUI update. Once per sheet.
    private func close() {
        guard let alert, !closing else { return }
        closing = true
        DispatchQueue.main.async {
            guard let parent = alert.window.sheetParent else { return }
            parent.endSheet(alert.window, returnCode: .abort)
        }
    }
}

/// The six digits in the "Allow …?" alert, as large as on the asking device, read digit by digit by VoiceOver.
private struct KeyCodeAccessory: View {
    let code: String

    var body: some View {
        Text(FirstRun.spacedCode(code))
            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            .tracking(3)
            .textSelection(.enabled)
            .padding(.vertical, 10)
            .frame(width: 228)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Code \(FirstRun.spokenCode(code))")
    }
}
