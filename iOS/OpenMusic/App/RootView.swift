import OpenMusicCore
import SwiftUI

@main
struct OpenMusicMobileApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    #if DEBUG
                    // A link that arrives during launch (a cold start from a link) waits for the handlers.
                    if let url = model.options.openURL { model.handle(url: url) }
                    #endif
                    await model.launch()
                    #if DEBUG
                    if let screen = model.options.screen { await SnapshotDriver(model: model).run(screen) }
                    if model.options.selfTest == "live" { await SelfTest(model: model).run() }
                    if model.options.selfTest == "perf", model.options.mock { await PerfSelfTest(model: model).run() }
                    #endif
                }
                .onOpenURL { model.handle(url: $0) }
                // Sync heartbeats only while in the foreground or playing; coming back reconnects at once.
                .onChange(of: scenePhase) { _, phase in model.sync?.setForeground(phase == .active) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var transition
    @State private var isShortScreen = false

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeTab().miniPlayerBanner()
            }
            Tab("New", systemImage: "square.grid.2x2.fill", value: AppTab.new) {
                NewTab().miniPlayerBanner()
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                LibraryTab().miniPlayerBanner()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchTab().miniPlayerBanner()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer(namespace: transition)
        }
        .fullScreenCover(isPresented: $model.isNowPlayingPresented) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "nowplaying", in: transition))
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView()
        }
        .sheet(item: $model.signInProvider) { id in
            if let provider = model.provider(id) {
                provider.makeSignInView { model.signInFinished() }
                    .presentationDetents(id == .spotify ? [.medium] : [.large])
            }
        }
        // The first-run flow: Welcome, Your music, Sync, Approve this device. Home loads underneath.
        .fullScreenCover(isPresented: Binding(get: { model.firstRun != nil }, set: { if !$0, model.firstRun != nil { model.finishFirstRun() } })) {
            if let flow = model.firstRun { FirstRunView(flow: flow) }
        }
        // Another device asks for this iPhone's sign-in key.
        .modifier(KeyRequestAlert())
        .overlay(alignment: .top) { ToastView() }
        .onGeometryChange(for: Bool.self) { geo in
            geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom < 740
        } action: { isShortScreen = $0 }
        .environment(\.isShortScreen, isShortScreen)
    }
}

private struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                Label(toast.text, systemImage: toast.symbol)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.toast)
        .sensoryFeedback(.success, trigger: model.toast) { _, new in new != nil && new?.symbol != "exclamationmark.triangle.fill" }
        .sensoryFeedback(.error, trigger: model.toast) { _, new in new?.symbol == "exclamationmark.triangle.fill" }
    }
}

private struct MiniPlayerBanner: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            // A firmer edge under the tab bar and mini player, so artwork and text scrolling beneath them don't read
            // through their labels.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let banner = model.extensions.miniPlayerBanner {
                    banner
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }
}

extension View {
    /// The slot above the mini player that extensions fill (`AppExtensions.miniPlayerBanner`).
    func miniPlayerBanner() -> some View { modifier(MiniPlayerBanner()) }
}
