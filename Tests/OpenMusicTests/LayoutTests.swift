import AppKit
import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

private func track(_ id: String, _ title: String, artist: String = "A", album: String? = nil, duration: TimeInterval? = nil, number: Int? = nil) -> Track {
    Track(providerID: id, provider: .youtubeMusic, title: title, artists: [ArtistRef(name: artist)],
          album: album.map { AlbumRef(title: $0) }, duration: duration, trackNumber: number)
}

private func playlist(_ id: String, _ title: String, category: Bool = false) -> MediaItem {
    .playlist(Playlist(providerID: id, provider: .youtubeMusic, title: title, extra: category ? ["category": "1"] : [:]))
}

// MARK: - Sort

@MainActor
@Suite struct TrackSortTests {
    let tracks = [
        track("1", "beta", artist: "Zed", album: "B", duration: 200),
        track("2", "Alpha", artist: "amy", album: nil, duration: nil),
        track("3", "Track 10", artist: "Bo", album: "A", duration: 100),
        track("4", "Track 2", artist: "Bo", album: "A", duration: 300),
    ]

    @Test func originalKeepsIndices() {
        #expect(TrackSort.original.ordered(tracks, indices: [3, 0, 2]) == [3, 0, 2])
    }

    @Test func titleIgnoresCaseAndSortsNumbersNaturally() {
        #expect(TrackSort.title.ordered(tracks, indices: Array(tracks.indices)) == [1, 0, 3, 2])
    }

    @Test func artistThenTitle() {
        #expect(TrackSort.artist.ordered(tracks, indices: Array(tracks.indices)) == [1, 3, 2, 0])
    }

    @Test func albumPutsMissingLast() {
        #expect(TrackSort.album.ordered(tracks, indices: Array(tracks.indices)) == [2, 3, 0, 1])
    }

    @Test func durationPutsUnknownLast() {
        #expect(TrackSort.duration.ordered(tracks, indices: Array(tracks.indices)) == [2, 0, 3, 1])
    }

    @Test func albumOrderIsConsistentWithMissingTrackNumbers() {
        let one = [track("a", "x", album: "Same", number: 2), track("b", "y", album: "Same"), track("c", "z", album: "Same", number: 1)]
        #expect(TrackSort.album.ordered(one, indices: [0, 1, 2]) == [2, 0, 1])
    }

    @Test func durationUsesTheLengthShownInRows() {
        // Track 4 is listed at 300 s but really plays for 50 s.
        let order = TrackSort.duration.ordered(tracks, indices: Array(tracks.indices)) { $0.providerID == "4" ? 50 : $0.duration }
        #expect(order == [3, 2, 0, 1])
    }

    /// A header click sorts by its column, the next reverses it, the third goes back to the original order; another
    /// column always starts ascending.
    @Test func headerClicksCycleAscendingDescendingOriginal() {
        var sort = TrackSort.original
        sort = sort.toggled(.title)
        #expect(sort == TrackSort(key: .title, ascending: true))
        sort = sort.toggled(.title)
        #expect(sort == TrackSort(key: .title, ascending: false))
        sort = sort.toggled(.title)
        #expect(sort == .original)
        #expect(sort.isOriginal)
        // Switching columns mid-cycle starts the new one ascending.
        sort = TrackSort(key: .title, ascending: false).toggled(.duration)
        #expect(sort == TrackSort(key: .duration, ascending: true))
        #expect(TrackSort.artist.toggled(.original) == .original)
    }

    @Test func descendingReversesAndKeepsMissingLast() {
        let desc = { (key: TrackSort.Key) in TrackSort(key: key, ascending: false).ordered(tracks, indices: Array(tracks.indices)) }
        #expect(desc(.title) == [2, 3, 0, 1])
        // No duration and no album still go last.
        #expect(desc(.duration) == [3, 0, 2, 1])
        #expect(desc(.album) == [0, 2, 3, 1])
        #expect(desc(.artist) == [0, 3, 2, 1])
    }

    @Test func descendingTiesKeepOriginalOrder() {
        let same = [track("a", "Same"), track("b", "Same"), track("c", "Same")]
        #expect(TrackSort(key: .title, ascending: false).ordered(same, indices: [0, 1, 2]) == [0, 1, 2])
    }

    @Test func tiesKeepOriginalOrder() {
        let same = [track("a", "Same"), track("b", "Same"), track("c", "Same")]
        #expect(TrackSort.title.ordered(same, indices: [0, 1, 2]) == [0, 1, 2])
    }

    /// Find and sort combine; Play from a row starts the whole list, in sorted order, at that song.
    @Test func listingCombinesFilterAndSortAndPlaysSortedOrder() {
        let listing = TrackListing(tracks: tracks, query: "track", sort: .duration, enabled: true)
        #expect(listing.filtering)
        #expect(listing.shown == [2, 3])
        #expect(listing.playOrder == [2, 0, 3, 1])
        // Row 1 is "Track 2" (index 3), third in the sorted whole list.
        #expect(listing.playStart(forRow: 1) == 2)
    }

    @Test func listingDisabledShowsEverythingInOrder() {
        let listing = TrackListing(tracks: tracks, query: "track", sort: .title, enabled: false)
        #expect(!listing.filtering)
        #expect(listing.shown == [0, 1, 2, 3])
        #expect(listing.playStart(forRow: 2) == 2)
    }
}

// MARK: - Album column

@MainActor
@Suite struct AlbumColumnTests {
    @Test func needsHalfTheRowsWithAnAlbum() {
        let mostlyEmpty = [track("1", "a", album: "X"), track("2", "b"), track("3", "c")]
        let half = [track("1", "a", album: "X"), track("2", "b")]
        #expect(!TrackListView.showsAlbumColumn(mostlyEmpty, width: 1160))
        #expect(TrackListView.showsAlbumColumn(half, width: 1160))
    }

    @Test func needsTableWidth() {
        let all = [track("1", "a", album: "X"), track("2", "b", album: "Y")]
        #expect(!TrackListView.showsAlbumColumn(all, width: 999))
        #expect(TrackListView.showsAlbumColumn(all, width: 1000))
    }
}

// MARK: - Home's featured item

@MainActor
@Suite struct HomeFeatureTests {
    let quickPicks = Shelf(id: "qp", title: "Quick picks", style: .trackList, items: [.track(track("t", "Song"))])
    let hits = Shelf(id: "hits", title: "Today's biggest hits", style: .carousel, items: [playlist("RDCLAK5uy_hits", "The Hit List"), playlist("RDCLAK5uy_2", "Pop")])
    let releases = Shelf(id: "new", title: "New releases", style: .carousel, items: [
        .album(Album(providerID: "MPREb_1", provider: .youtubeMusic, title: "Record")),
        playlist("RDTMAK5uy_mix", "New Release Mix"),
    ])

    @Test func prefersPersonalShelf() {
        let listenAgain = Shelf(id: "la", title: "Listen again", style: .carousel, items: [.track(track("x", "Song")), playlist("PLmine", "Road trip")])
        let pick = HomeFeature.pick(from: [(.youtubeMusic, quickPicks), (.youtubeMusic, hits), (.youtubeMusic, listenAgain)])
        #expect(pick?.item.id == playlist("PLmine", "Road trip").id)
        #expect(pick?.shelfTitle == "Listen again")
    }

    @Test func thenAMixAnywhere() {
        let pick = HomeFeature.pick(from: [(.youtubeMusic, quickPicks), (.youtubeMusic, hits), (.youtubeMusic, releases)])
        #expect(pick?.item.id == playlist("RDTMAK5uy_mix", "New Release Mix").id)
        #expect(pick?.shelfID == "new")
    }

    @Test func thenFirstPlaylistShelf() {
        let pick = HomeFeature.pick(from: [(.youtubeMusic, quickPicks), (.youtubeMusic, hits)])
        #expect(pick?.item.id == playlist("RDCLAK5uy_hits", "The Hit List").id)
        #expect(pick?.shelfTitle == "Today's biggest hits")
    }

    @Test func userPlaylistNamedMixIsNotAMix() {
        #expect(!HomeFeature.isMix(playlist("PLabc", "Workout Mix")))
        #expect(HomeFeature.isMix(playlist("RDCLAK5uy_x", "Chill Mix")))
        #expect(!HomeFeature.isMix(playlist("RDCLAK5uy_y", "70's Mixed Rock")))
    }

    @Test func picksOnePerShelfAndPassesOverPinned() {
        let listenAgain = Shelf(id: "la", title: "Listen again", style: .carousel, items: [playlist("PLpinned", "Pinned one"), playlist("PLmine", "Road trip")])
        let mixes = Shelf(id: "mx", title: "Mixed for you", style: .carousel, items: [playlist("RDTMAK5uy_a", "My Mix 1"), playlist("RDTMAK5uy_b", "My Mix 2")])
        let shelves: [(ProviderID, Shelf)] = [(.youtubeMusic, quickPicks), (.youtubeMusic, listenAgain), (.youtubeMusic, mixes), (.youtubeMusic, hits)]
        let pinned = SidebarEntry.item(playlist("PLpinned", "Pinned one")).id
        let picks = HomeFeature.picks(from: shelves, avoiding: [pinned], limit: 3)
        #expect(picks.map(\.item.title) == ["My Mix 1", "Road trip", "The Hit List"])
        #expect(Set(picks.map(\.shelfID)).count == picks.count)
        // Nothing else to feature: the pinned item is used after all.
        let only = Shelf(id: "la2", title: "Listen again", style: .carousel, items: [playlist("PLpinned", "Pinned one")])
        #expect(HomeFeature.picks(from: [(.youtubeMusic, only)], avoiding: [pinned], limit: 3).map(\.item.title) == ["Pinned one"])
    }

    @Test func neverFeaturesMoodTilesOrSongs() {
        let moods = Shelf(id: "m", title: "Moods", style: .carousel, items: [playlist("cat", "Chill", category: true)])
        #expect(HomeFeature.pick(from: [(.youtubeMusic, quickPicks), (.youtubeMusic, moods)]) == nil)
    }
}

// MARK: - Card layout

@MainActor
@Suite struct CardLayoutTests {
    /// The short-window card range gives four smaller cards at 960 pt with the sidebar, not three 210 pt ones.
    @Test func compactRangeFitsMoreSmallerCards() {
        let available: CGFloat = 960 - 220 - 2 * Metrics.pageInset
        let normal = Metrics.cardLayout(available: available)
        let compact = Metrics.cardLayout(available: available, widths: Metrics.compactCardWidths)
        #expect(normal.width > 200)
        #expect(compact.columns > normal.columns)
        #expect(compact.width <= 176)
    }

    /// The last card ends on the trailing margin: the stepped width's leftover goes into the gaps, never below the
    /// shelf's own spacing, and a gap that would grow past its stretch limit grows the cards instead.
    @Test func lastCardEndsOnTheMargin() {
        let ranges: [(ClosedRange<CGFloat>, CGFloat, Bool)] = [
            (Metrics.cardWidths, Metrics.cardSpacing, false), (Metrics.featuredCardWidths, Metrics.cardSpacing, false),
            (Metrics.videoCardWidths, Metrics.cardSpacing, false), (Metrics.compactCardWidths, Metrics.cardSpacing, false),
            (HeroCard.widths, Metrics.cardSpacing, true), (190...250, 14, false), (290...2000, 24, false),
        ]
        for available in stride(from: CGFloat(340), through: 2400, by: 0.5) {
            for (widths, spacing, fills) in ranges where available >= 2 * widths.lowerBound + spacing {
                let layout = Metrics.cardLayout(available: available, widths: widths, spacing: spacing, fills: fills)
                let end = CGFloat(layout.columns) * layout.width + CGFloat(layout.columns - 1) * layout.spacing
                #expect(abs(end - available) < 0.001, "\(widths) at \(available): ends at \(end)")
                #expect(layout.spacing >= spacing)
                #expect(layout.spacing <= spacing * Metrics.cardSpacingStretch + Metrics.cardWidthStep)
                #expect(layout.width.truncatingRemainder(dividingBy: Metrics.cardWidthStep) == 0 || layout.width == widths.upperBound)
            }
        }
        // 1440 pt window with the sidebar: six 172 pt cards, 24 pt apart, ending at 1152.
        let home = Metrics.cardLayout(available: 1440 - 232 - 2 * Metrics.pageInset)
        #expect(home.columns == 6 && home.width == 172 && home.spacing == 24)
    }
}

@MainActor
@Suite struct SignedOutHomeTests {
    /// A signed-out first launch: charts, new releases and moods, nothing drawn from a listener's history.
    @Test func signedOutHomeHasNothingPersonal() async throws {
        let shelves = try await MockProvider(id: .youtubeMusic, signedIn: false).home()
        let titles = shelves.map { $0.title.lowercased() }
        #expect(titles.contains("top songs"))
        #expect(titles.contains("new releases"))
        #expect(titles.contains("moods & genres"))
        #expect(!titles.contains { title in HomeFeature.personalShelves.contains(where: title.contains) })
        let liked = shelves.flatMap(\.items).contains { if case .playlist(let p) = $0 { p.title == "Liked Music" } else { false } }
        #expect(!liked)
        // So Home leads with no "From Listen again" card either.
        #expect(HomeFeature.picks(from: shelves.map { (.youtubeMusic, $0) }, limit: 3).isEmpty)

        let signedIn = try await MockProvider(id: .youtubeMusic).home().map(\.title)
        #expect(signedIn.contains("Listen again"))
    }
}

// MARK: - Collection hero action row

@MainActor
@Suite struct CollectionHeroActionsTests {
    /// Play, Shuffle, Add and More on an album: about 306 pt.
    let albumActions: CGFloat = 306

    @Test func noToolsAddNothing() {
        #expect(CollectionHeroMetrics.rowWidth(actions: albumActions, tools: 0, compact: false) == albumActions)
    }

    @Test func toolsAddTheSpacerAndBothGaps() {
        #expect(CollectionHeroMetrics.rowWidth(actions: albumActions, tools: 200, compact: false) == albumActions + 18 + 12 + 18 + 200)
        #expect(CollectionHeroMetrics.rowWidth(actions: albumActions, tools: 200, compact: true) == albumActions + 14 + 12 + 14 + 200)
    }

    /// Beside the cover with the Lyrics panel open in a 1440 pt window (a ~927 pt pane) and down to a 700 pt pane.
    @Test func albumActionsStayBesideTheCover() {
        let row = CollectionHeroMetrics.rowWidth(actions: albumActions, tools: 0, compact: false)
        #expect(CollectionHeroMetrics.fitsInline(paneWidth: 927, actions: row, compact: false))
        #expect(CollectionHeroMetrics.fitsInline(paneWidth: 700, actions: row, compact: false))
        #expect(!CollectionHeroMetrics.fitsInline(paneWidth: 500, actions: row, compact: false))
    }
}

// MARK: - Column widths

/// `SplitViewTuning`'s arithmetic for both layouts: macOS 26 and later, where the window has to hold the sidebar's
/// width twice, and macOS 15, where the columns sit side by side.
@Suite struct ColumnWidthTests {
    @Test func sidebarShareFollowsTheSystem() {
        let modern = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        #expect(SplitViewTuning.sidebarShare == (modern ? 2 : 1))
        #expect(SplitViewTuning.neededWidth(sidebar: 220, panel: 310) == SplitViewTuning.neededWidth(sidebar: 220, panel: 310, sidebarShare: modern ? 2 : 1))
    }

    @Test func macOS26CountsTheSidebarTwice() {
        // The measured abort threshold: sidebar 220 and lyrics 421 need 1281 pt plus the dividers.
        #expect(SplitViewTuning.neededWidth(sidebar: 220, panel: 421, sidebarShare: 2) == 1283)
        // At the 900 pt minimum with no panel the sidebar can be 239 wide, not its 300 maximum.
        #expect(SplitViewTuning.sidebarRoom(windowWidth: 900, panelWidth: 0, sidebarShare: 2) == 239)
        #expect(SplitViewTuning.panelRoom(windowWidth: 1100, sidebarWidth: 190, sidebarShare: 2) == 298)
        // Resizing keeps the sidebar at its minimum beside the panel's ideal width down to 1112 pt (190 × 2 + 420 + 310 + 2).
        #expect(SplitViewTuning.neededWidth(sidebar: SplitViewTuning.sidebarMinWidth, panel: InspectorMetrics.idealWidth, sidebarShare: 2) == 1112)
        // Showing the sidebar beside a panel takes its 232 pt ideal width: from 1196 pt (232 × 2 + 420 + 310 + 2).
        #expect(SplitViewTuning.sidebarIdealWidth == 232)
        #expect(SidebarMetrics.idealWidth == SplitViewTuning.sidebarIdealWidth)
        #expect(SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 1196, sidebarShare: 2))
        #expect(!SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 1195, sidebarShare: 2))
        #expect(!SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 1172, sidebarShare: 2))
        #expect(!SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 1150, sidebarShare: 2))
        #expect(!SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 960, sidebarShare: 2))
        // A panel still opening (narrower than its ideal) counts at its ideal width.
        #expect(!SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 1150, panelWidth: 100, sidebarShare: 2))
        // Beside a wider panel the sidebar needs more: a 520 pt queue and the sidebar don't share 1200 pt.
        #expect(SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 1200, panelWidth: 310, sidebarShare: 2))
        #expect(!SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 1200, panelWidth: 520, sidebarShare: 2))
        // Wide lyrics (420) beside the sidebar at its ideal width need 1306 pt: a 1300 pt window has 414 for them.
        #expect(SplitViewTuning.panelRoom(windowWidth: 1300, sidebarWidth: 232, sidebarShare: 2) == 414)
        #expect(SplitViewTuning.panelRoom(windowWidth: 1440, sidebarWidth: 232, sidebarShare: 2) >= InspectorMetrics.lyricsWidth)
    }

    @Test func macOS15CountsTheSidebarOnce() {
        // A 900 pt window holds a 300 pt sidebar beside the 420 pt page.
        #expect(SplitViewTuning.neededWidth(sidebar: 300, panel: 0, sidebarShare: 1) == 722)
        #expect(SplitViewTuning.sidebarRoom(windowWidth: 900, panelWidth: 0, sidebarShare: 1) >= SplitViewTuning.sidebarMaxWidth)
        // And the sidebar at its minimum beside a panel at its minimum.
        #expect(SplitViewTuning.panelRoom(windowWidth: 900, sidebarWidth: 190, sidebarShare: 1) >= InspectorMetrics.minWidth)
        // Resizing keeps sidebar and panel together down to 922 pt (190 + 420 + 310 + 2); showing the sidebar beside a
        // panel takes 964 (232 + 420 + 310 + 2): at 964, yes; at 960 and 900, no.
        #expect(SplitViewTuning.neededWidth(sidebar: SplitViewTuning.sidebarMinWidth, panel: InspectorMetrics.idealWidth, sidebarShare: 1) == 922)
        #expect(SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 964, sidebarShare: 1))
        #expect(!SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 960, sidebarShare: 1))
        #expect(!SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 900, sidebarShare: 1))
        #expect(SplitViewTuning.sidebarFitsBesidePanel(windowWidth: 1200, panelWidth: 520, sidebarShare: 1))
    }
}

// MARK: - Window frames around the sidebar's animation

@MainActor
@Suite struct WindowFrameRuleTests {
    let current = CGRect(x: 60, y: 60, width: 1100, height: 900)

    @Test func narrowingBelowTheFloorIsClampedAndRemembered() {
        var deferral = ShrinkDeferral(floor: 1100)
        let requested = CGRect(x: 60, y: 40, width: 900, height: 880)
        let applied = deferral.adjust(current: current, requested: requested, intent: true)
        #expect(applied == CGRect(x: 60, y: 40, width: 1100, height: 880))
        #expect(deferral.intent == requested)
        #expect(deferral.frameAtEnd(current: applied) == requested)
    }

    @Test func aLeftEdgeDragKeepsTheRightEdge() {
        var deferral = ShrinkDeferral(floor: 1100)
        // The left edge dragged 200 pt right: the window stays 1100 wide with its right edge where it was.
        let requested = CGRect(x: 260, y: 60, width: 900, height: 900)
        #expect(deferral.adjust(current: current, requested: requested, intent: true) == current)
    }

    @Test func theLatestIntentWins() {
        var deferral = ShrinkDeferral(floor: 1100)
        _ = deferral.adjust(current: current, requested: CGRect(x: 60, y: 60, width: 1000, height: 900), intent: true)
        _ = deferral.adjust(current: current, requested: CGRect(x: 60, y: 60, width: 900, height: 900), intent: true)
        #expect(deferral.intent?.width == 900)
        let wider = CGRect(x: 60, y: 60, width: 1300, height: 900)
        #expect(deferral.adjust(current: current, requested: wider, intent: true) == wider)
        // The widening is in place: nothing left to apply at the end.
        #expect(deferral.frameAtEnd(current: wider) == nil)
    }

    @Test func swiftUIsOwnFramesAreNeverRemembered() {
        // No intent: SwiftUI's shrinks during the animation are clamped to the floor and nothing is applied after.
        var deferral = ShrinkDeferral(floor: 960)
        let at960 = CGRect(x: 60, y: 60, width: 960, height: 900)
        for width: CGFloat in [620, 627, 655, 742, 872, 915, 940, 955] {
            let step = CGRect(x: 60, y: 60, width: width, height: 900)
            #expect(deferral.adjust(current: at960, requested: step, intent: false) == at960)
        }
        #expect(deferral.intent == nil)
        #expect(deferral.frameAtEnd(current: at960) == nil)
    }

    @Test func aWideningDuringTheAnimationIsFinal() {
        // The review's trace: the window at 960 is widened to 1300 150 ms into the animation; SwiftUI then sets it
        // back to 960 and steps toward 955. The widening goes through at once, SwiftUI's frames stay at 1300, and
        // the window ends at 1300.
        var deferral = ShrinkDeferral(floor: 960)
        let at960 = CGRect(x: 60, y: 60, width: 960, height: 900)
        let wide = CGRect(x: 60, y: 60, width: 1300, height: 900)
        #expect(deferral.adjust(current: at960, requested: wide, intent: true) == wide)
        for width: CGFloat in [960, 620, 627, 655, 742, 872, 915, 940, 955, 1006, 1248] {
            let step = CGRect(x: 60, y: 60, width: width, height: 900)
            #expect(deferral.adjust(current: wide, requested: step, intent: false) == wide)
        }
        #expect(deferral.frameAtEnd(current: wide) == nil)
        // Had a SwiftUI frame got through some other way, the end puts the widening back.
        #expect(deferral.frameAtEnd(current: at960) == wide)
    }

    @Test func aNarrowerIntentAfterAWideningIsKept() {
        // Widened to 1300, then dragged back to 1000 (still above the 960 floor): 1000 is the size to keep.
        var deferral = ShrinkDeferral(floor: 960)
        let wide = CGRect(x: 60, y: 60, width: 1300, height: 900)
        _ = deferral.adjust(current: CGRect(x: 60, y: 60, width: 960, height: 900), requested: wide, intent: true)
        let back = CGRect(x: 60, y: 60, width: 1000, height: 900)
        #expect(deferral.adjust(current: wide, requested: back, intent: true) == back)
        #expect(deferral.adjust(current: back, requested: CGRect(x: 60, y: 60, width: 960, height: 900), intent: false) == back)
        #expect(deferral.frameAtEnd(current: back) == nil)
    }

    @Test func onlyTheRequestedCallIsIntentNotARequestNestedInIt() {
        // The app asks for 1300 through `requestFrame` 150 ms into the animation. While AppKit applies it, SwiftUI's
        // hosting view asks for 960 from inside that call. Only the first is intent; the nested one is SwiftUI's,
        // is clamped to the 1300 just asked for, and the window ends at 1300.
        var marker = FrameIntentMarker()
        var deferral = ShrinkDeferral(floor: 960)
        // Kept alive for the whole test, so the two identifiers stay distinct.
        let windows = (NSObject(), NSObject())
        let main = ObjectIdentifier(windows.0)
        let other = ObjectIdentifier(windows.1)
        defer { withExtendedLifetime(windows) {} }
        let at960 = CGRect(x: 60, y: 60, width: 960, height: 900)
        let wide = CGRect(x: 60, y: 60, width: 1300, height: 900)

        let previous = marker.mark(main, wide)
        // The exchanged setFrame consumes the mark before calling AppKit.
        let outerIsIntent = marker.consume(main, wide)
        #expect(outerIsIntent)
        #expect(deferral.adjust(current: at960, requested: wide, intent: outerIsIntent) == wide)
        // Reentrant, inside AppKit's setFrame: no mark left.
        let nestedIsIntent = marker.consume(main, at960)
        #expect(!nestedIsIntent)
        #expect(deferral.adjust(current: wide, requested: at960, intent: nestedIsIntent) == wide)
        marker = previous
        #expect(deferral.intent == wide)
        #expect(deferral.frameAtEnd(current: wide) == nil)
        #expect(deferral.frameAtEnd(current: at960) == wide)

        // A mark is for its own window and frame only.
        _ = marker.mark(main, wide)
        let otherWindow = marker.consume(other, wide)
        let ownWindow = marker.consume(main, wide)
        #expect(!otherWindow)
        #expect(ownWindow)
        _ = marker.mark(main, wide)
        let otherFrame = marker.consume(main, at960)
        let usedUp = marker.consume(main, wide)
        #expect(!otherFrame)
        #expect(!usedUp)
    }

    @Test func appKitsWideningIsPutBack() {
        let original = CGRect(x: 60, y: 60, width: 960, height: 900)
        var correction = WidthCorrection(original: original, stamp: 7)
        let widened = CGRect(x: 60, y: 60, width: 1181, height: 900)
        correction.windowResized(to: widened, stamp: 7)
        #expect(correction.correctedFrame(current: widened, stamp: 7) == original)
    }

    @Test func aNewerWindowActionKeepsItsWidth() {
        let original = CGRect(x: 60, y: 60, width: 960, height: 900)
        var correction = WidthCorrection(original: original, stamp: 7)
        // A setFrame, live resize, zoom, tiling or full screen moves the stamp on: nothing to put back.
        let widened = CGRect(x: 60, y: 60, width: 1300, height: 900)
        correction.windowResized(to: widened, stamp: 8)
        #expect(correction.correctedFrame(current: widened, stamp: 8) == nil)
        // Even after AppKit's own widening, a newer action wins.
        var afterAppKit = WidthCorrection(original: original, stamp: 7)
        afterAppKit.windowResized(to: CGRect(x: 60, y: 60, width: 1181, height: 900), stamp: 7)
        #expect(afterAppKit.correctedFrame(current: widened, stamp: 8) == nil)
        // And with no widening at all there is nothing to correct.
        #expect(WidthCorrection(original: original, stamp: 7).correctedFrame(current: widened, stamp: 7) == nil)
    }
}
