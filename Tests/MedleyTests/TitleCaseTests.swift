import Testing
@testable import Medley

@Suite struct TitleCaseTests {
    @Test func capitalizesEachWordButMinorOnes() {
        #expect("Quick picks".titleCased() == "Quick Picks")
        #expect("Made For You".titleCased() == "Made for You")
        #expect("New releases for you".titleCased() == "New Releases for You")
        #expect("Your top songs this month".titleCased() == "Your Top Songs This Month")
        #expect("Moods & genres".titleCased() == "Moods & Genres")
        #expect("songs of the year in a row on repeat".titleCased() == "Songs of the Year in a Row on Repeat")
    }

    @Test func firstAndLastWordsAreAlwaysCapitalized() {
        #expect("the best of".titleCased() == "The Best Of")
        #expect("Artists you listen to".titleCased() == "Artists You Listen To")
        #expect("a mix: the hits".titleCased() == "A Mix: The Hits")
    }

    @Test func leavesAllCapsAndMixedCaseWordsAlone() {
        #expect("BIRDS of a feather".titleCased() == "BIRDS of a Feather")
        #expect("DJ mixes".titleCased() == "DJ Mixes")
        #expect("made on iPhone".titleCased() == "Made on iPhone")
        #expect("THE BEST OF THE 80S".titleCased() == "THE BEST OF THE 80S")
        #expect("McCartney classics".titleCased() == "McCartney Classics")
    }

    @Test func keepsSpacingAndPunctuation() {
        #expect("".titleCased() == "")
        #expect("listen  again".titleCased() == "Listen  Again")
        #expect("(live) sessions 2024".titleCased() == "(Live) Sessions 2024")
        #expect("United States".titleCased() == "United States")
    }
}
