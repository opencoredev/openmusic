import Foundation

extension String {
    /// Shelf and section titles in title case for display, as Apple Music sets them: "Quick picks" → "Quick Picks",
    /// "Made For You" → "Made for You". Each word is capitalized except a, an, and, for, of, the, to, in, on and &,
    /// which stay lowercase unless they open or close the title (or follow a colon or dash): "Artists You Listen To".
    /// A word with a capital after its first letter (BIRDS, DJ, iPhone, McCartney) is left as written. Display only:
    /// the shelf's data keeps the service's own text, so lookups and caches still match.
    nonisolated func titleCased() -> String {
        var startsClause = true
        let parts = split(separator: " ", omittingEmptySubsequences: false)
        let last = parts.lastIndex { !$0.isEmpty }
        return parts.indices.map { index -> String in
            let word = String(parts[index])
            defer {
                if !word.isEmpty { startsClause = word.hasSuffix(":") || word == "—" || word == "–" || word == "-" }
            }
            guard let firstLetter = word.firstIndex(where: \.isLetter) else { return word }
            let letters = word[firstLetter...].filter(\.isLetter)
            if letters.dropFirst().contains(where: \.isUppercase) { return word }
            let core = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if !startsClause, index != last, String.titleCaseMinorWords.contains(core) { return word.lowercased() }
            var result = word
            result.replaceSubrange(firstLetter...firstLetter, with: word[firstLetter].uppercased())
            return result
        }.joined(separator: " ")
    }

    private nonisolated static let titleCaseMinorWords: Set<String> = ["a", "an", "and", "for", "of", "the", "to", "in", "on"]
}
