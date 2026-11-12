import Foundation
import MedleyCore
import Testing
@testable import Medley

@MainActor
@Suite struct FittedLineTests {
    @Test func listDropsNamesFromTheEndAndKeepsAndMore() {
        let variants = FittedLine.makeVariants(of: "Remi Wolf, SZA, Ella Langley and more")
        #expect(Array(variants.prefix(3)) == ["Remi Wolf, SZA, Ella Langley and more", "Remi Wolf, SZA and more", "Remi Wolf and more"])
        // Narrower still: whole words of the shortest list, never part of one.
        #expect(variants.dropFirst(3).allSatisfy { $0.hasSuffix("…") })
        #expect(Array(variants.dropFirst(3)) == ["Remi Wolf…", "Remi…"])
    }

    @Test func otherTextEndsOnAWholeWord() {
        let variants = FittedLine.makeVariants(of: "Album · Olivia Rodrigo, Chappell Roan")
        #expect(variants.first == "Album · Olivia Rodrigo, Chappell Roan")
        #expect(variants.contains("Album · Olivia Rodrigo, Chappell…"))
        // Punctuation before the cut goes with it.
        #expect(variants.contains("Album · Olivia Rodrigo…"))
        #expect(variants.contains("Album…"))
        #expect(!variants.contains { $0.hasSuffix(",…") || $0.hasSuffix("·…") })
    }

    @Test func cardSubtitleKeepsItsLabelAndWholeNames() {
        // Round 27's search card read "Single · Olivia Rodrigo…".
        let variants = FittedLine.variants(prefix: "Single · ", names: ["Olivia Rodrigo", "Olivia Dean"])
        #expect(Array(variants.prefix(4)) == ["Single · Olivia Rodrigo, Olivia Dean", "Single · Olivia Rodrigo and more",
                                              "Olivia Rodrigo, Olivia Dean", "Olivia Rodrigo and more"])
        // A name is cut only after every whole-name variant, and then the label stays.
        let firstCut = variants.firstIndex { $0.hasSuffix("…") } ?? variants.count
        #expect(variants[..<firstCut].allSatisfy { !$0.hasSuffix("…") })
        #expect(variants[firstCut...].allSatisfy { $0.hasPrefix("Single · ") })
        let album = MediaItem.album(Album(providerID: "x", provider: .youtubeMusic, title: "expectations",
                                          artists: [ArtistRef(name: "Olivia Rodrigo"), ArtistRef(name: "Olivia Dean")], kind: .single))
        let parts = album.cardSubtitleNames()
        #expect(parts?.prefix == "Single · ")
        #expect(parts.map { $0.prefix + $0.names.joined(separator: ", ") } == album.cardSubtitle())
        #expect(album.cardSubtitleNames(style: .discography) == nil)
    }

    @Test func picksTheLongestVariantThatFits() {
        let variants = FittedLine.makeVariants(of: "A, B, C and more")
        // A stand-in measure: 10 pt a character.
        let measure: (String) -> CGFloat = { CGFloat($0.count * 10) }
        #expect(variants[FittedLine.index(of: variants, fitting: 1000, measure: measure)] == "A, B, C and more")
        #expect(variants[FittedLine.index(of: variants, fitting: 130, measure: measure)] == "A, B and more")
        #expect(variants[FittedLine.index(of: variants, fitting: 100, measure: measure)] == "A and more")
        // Nothing fits: the shortest.
        #expect(FittedLine.index(of: variants, fitting: 5, measure: measure) == variants.count - 1)
    }

    @Test func artistNamesStayWhole() {
        let names = ["HUNTR/X", "EJAE", "AUDREY NUNA", "REI AMI", "KPop Demon Hunters Cast"]
        let variants = FittedLine.makeVariants(ofNames: names)
        #expect(variants.first == "HUNTR/X, EJAE, AUDREY NUNA, REI AMI, KPop Demon Hunters Cast")
        #expect(Array(variants.dropFirst().prefix(4)) == ["HUNTR/X, EJAE, AUDREY NUNA, REI AMI and more", "HUNTR/X, EJAE, AUDREY NUNA and more",
                                                          "HUNTR/X, EJAE and more", "HUNTR/X and more"])
        // Never a list cut mid-name.
        #expect(!variants.contains { $0.hasSuffix(",…") })
        // Two names: both, then the first and "and more".
        #expect(Array(FittedLine.makeVariants(ofNames: ["Olivia Rodrigo", "Robert Smith"]).prefix(2)) == ["Olivia Rodrigo, Robert Smith", "Olivia Rodrigo and more"])
        // One name: the plain variants.
        #expect(FittedLine.variants(ofNames: ["Olivia Dean"]) == FittedLine.makeVariants(of: "Olivia Dean"))
        let measure: (String) -> CGFloat = { CGFloat($0.count * 7) }
        #expect(variants[FittedLine.index(of: variants, fitting: 160, measure: measure)] == "HUNTR/X, EJAE and more")
    }

    @Test func singleWordHasOneVariant() {
        #expect(FittedLine.makeVariants(of: "Throwbacks") == ["Throwbacks"])
        #expect(FittedLine.makeVariants(of: "Ivy Crane and more") == ["Ivy Crane and more", "Ivy Crane…", "Ivy…"])
    }
}

@MainActor
@Suite struct CompactRowPlayLabelTests {
    @Test func saysWhatTheButtonDoes() {
        #expect(CompactTrackRow.playLabel(title: "the cure", togglesInPlace: true, isPlaying: true) == "Pause the cure")
        #expect(CompactTrackRow.playLabel(title: "the cure", togglesInPlace: true, isPlaying: false) == "Resume the cure")
        // The same song playing from another list: the button starts this one.
        #expect(CompactTrackRow.playLabel(title: "the cure", togglesInPlace: false, isPlaying: true) == "Play the cure")
        #expect(CompactTrackRow.playLabel(title: "the cure", togglesInPlace: false, isPlaying: false) == "Play the cure")
    }

    /// Mix cards' subtitles (round 26: "Kendrick Lamar, Dominic Fike, ADÉLA an…", "Catch all the latest music from
    /// artists yo…"): in a card's 13 pt line they end on a whole name with "and more", or after a whole word.
    @Test func cardSubtitlesEndOnWholeWords() {
        let mix = "Kendrick Lamar, Dominic Fike, ADÉLA and more"
        let prose = "Catch all the latest music from artists you follow, plus new singles picked for you."
        for width in stride(from: CGFloat(120), through: 220, by: 10) {
            let names = FittedLine.variants(of: mix)[FittedLine.index(of: mix, fitting: width, size: 13)]
            #expect(names.hasSuffix(" and more") || names.hasSuffix("…"), "\(width): \(names)")
            #expect(!names.contains(" an…") && !names.hasSuffix("ADÉ…"), "\(width): \(names)")
            let line = FittedLine.variants(of: prose)[FittedLine.index(of: prose, fitting: width, size: 13)]
            // Every cut ends a word of the original: what's before "…" is a prefix ending at a space or comma.
            let head = String(line.dropLast())
            #expect(line.hasSuffix("…"), "\(width): \(line)")
            #expect(prose.hasPrefix(head) && [" ", ","].contains(prose[prose.index(prose.startIndex, offsetBy: head.count)]), "\(width): \(line)")
            #expect(FittedLine.width(line, size: 13) <= width || line == FittedLine.variants(of: prose).last)
        }
        #expect(FittedLine.variants(of: mix).contains("Kendrick Lamar, Dominic Fike and more"))
    }

    /// Two lines (the hero cards' band): twice the width less the widest word, so the pick surely wraps into two.
    @Test func twoLinesLeaveRoomForTheBreak() {
        let text = "Catch all the latest music from artists you follow, plus new singles picked for you."
        let widest = text.split(separator: " ").map { FittedLine.width(String($0), size: 12) }.max() ?? 0
        #expect(FittedLine.room(for: text, width: 240, lines: 1, size: 12) == 240)
        #expect(FittedLine.room(for: text, width: 240, lines: 2, size: 12) == 480 - widest)
        let mix = "Kendrick Lamar, Dominic Fike, ADÉLA and more"
        // A 244 pt card less its 14 pt padding each side: the whole list on two lines.
        let index = FittedLine.index(of: mix, fitting: FittedLine.room(for: mix, width: 216, lines: 2, size: 12), size: 12)
        #expect(FittedLine.variants(of: mix)[index] == mix)
    }

    /// The hero card's mix names on one line (round 28 left "and more" alone on the second): in the band of a
    /// 272 pt card at a 1440 pt window (244 pt inside its padding) the whole list doesn't fit, so the pick drops
    /// names from the end and keeps "and more" with them; narrower, fewer names, never a cut word.
    @Test func mixNamesFitOneLine() {
        let mix = "Kendrick Lamar, Dominic Fike, ADÉLA and more"
        for width in [CGFloat(208), 244, 272] {
            let picked = FittedLine.variants(of: mix)[FittedLine.index(of: mix, fitting: width, size: 12)]
            #expect(picked.hasSuffix(" and more"), "\(width): \(picked)")
            #expect(FittedLine.width(picked, size: 12) <= width, "\(width): \(picked)")
        }
        #expect(FittedLine.width(mix, size: 12) > 244)
        #expect(FittedLine.variants(of: mix)[FittedLine.index(of: mix, fitting: 244, size: 12)] == "Kendrick Lamar, Dominic Fike and more")
    }
}
