import MedleyCore
import SwiftUI

/// The sidebar search field: text, suggestions, focus and submit. Applied once to the main window.
///
/// Suggestions start with a direct artist match when a service has one (picture and "Artist"); picking it
/// opens the artist page. The rest are query completions; picking one searches for it.
///
/// The popover closes when a result opens, a suggestion is picked, Return is pressed or the app navigates
/// anywhere (`AppModel.suggestionsDismissedFor`), keeping the query. It comes back once the text is edited.
struct SearchField: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var suggestions = SearchFieldSuggestions()
    @FocusState private var searchFocus: Bool

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            // Return in the field. Attached on both sides of `searchable` because which side AppKit's sidebar
            // field reads has changed between releases; `submitSearch` is idempotent.
            .onSubmit(of: .search) { model.submitSearch() }
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
            .searchSuggestions {
                if let artist = suggestions.artist {
                    ArtistSuggestionRow(artist: artist)
                        .searchCompletion(SearchFieldSuggestions.completion(for: artist))
                }
                ForEach(suggestions.queries, id: \.self) { s in
                    Label(s, systemImage: "magnifyingglass").searchCompletion(s)
                }
            }
            .searchFocused($searchFocus)
            .onSubmit(of: .search) { model.submitSearch() }
            .onChange(of: model.searchFocused) { _, focused in
                if focused { searchFocus = true; model.searchFocused = false }
            }
            .task(id: model.searchText) { await loadSuggestions(model.searchText) }
            .onChange(of: model.suggestionsDismissed) { _, dismissed in
                if dismissed { publish(SearchFieldSuggestions()) }
            }
    }

    private func loadSuggestions(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, text.last != SearchFieldSuggestions.artistMarker, !model.suggestionsDismissed else {
            return publish(SearchFieldSuggestions())
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, !model.suggestionsDismissed else { return }
        var lists: [SearchSuggestions] = []
        for provider in model.searchProviders {
            if let list = try? await provider.richSearchSuggestions(q) { lists.append(list) }
        }
        // A result may have opened while the services answered.
        guard !Task.isCancelled else { return }
        guard !model.suggestionsDismissed else { return publish(SearchFieldSuggestions()) }
        publish(SearchFieldSuggestions.make(query: q, from: lists))
    }

    private func publish(_ new: SearchFieldSuggestions) {
        suggestions = new
        model.offeredSuggestions = new
    }
}

/// The direct artist match at the top of the suggestions.
private struct ArtistSuggestionRow: View {
    let artist: Artist

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(artwork: artist.artwork, size: 28, cornerRadius: 14, circle: true, symbol: "music.mic")
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(artist.name).lineLimit(1)
                Text("Artist").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name), artist")
    }
}
