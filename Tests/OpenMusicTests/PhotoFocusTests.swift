import CoreGraphics
import Foundation
import Testing
@testable import OpenMusic

/// The artist hero's full-bleed photo: the subject in the right part of the frame, the face in view and above the
/// fade, no gap at the trailing edge, and no more than `maxUpscale` device pixels per source pixel.
struct PhotoFocusTests {
    /// The banner at a 1440 pt window with the sidebar (page about 1207 pt) and at 960 pt with it collapsed.
    static let banners = [CGSize(width: 1207, height: 380), CGSize(width: 960, height: 320)]

    private func face(_ face: CGRect, aspect: CGFloat = 1, sourceWidth: Int? = 1000) -> PhotoFocus {
        let head = PhotoFocus.head(fromFace: face)
        var focus = PhotoFocus(aspect: aspect, subject: head, primary: head, source: .face)
        focus.sourceWidth = sourceWidth
        return focus
    }

    private func check(_ focus: PhotoFocus, banner: CGSize, centerIn range: ClosedRange<CGFloat> = 0.6...0.75) -> HeroPhotoPlacement {
        let p = focus.placement(banner: banner, displayScale: 2)
        // Covers the banner's height and its trailing edge.
        #expect(p.origin.y <= 0.001 && p.origin.y + p.size.height >= banner.height - 0.001)
        #expect(p.origin.x + p.size.width >= banner.width - 0.001)
        if let up = p.upscale(sourceWidth: focus.sourceWidth, displayScale: 2) {
            // Never past the cap, unless the banner itself needs it (the photo must at least cover the banner).
            let floor = max(banner.width, banner.height * focus.aspect) * 2 / CGFloat(focus.sourceWidth ?? 1)
            #expect(up <= max(PhotoFocus.maxUpscale, floor) + 0.001)
        }
        if let subject = focus.subject {
            let center = (p.origin.x + subject.midX * p.size.width) / banner.width
            #expect(range.contains(center), "subject center at \(center)")
        }
        if focus.source == .face, let head = focus.subject {
            let shown = p.visibleRect(banner: banner)
            let faceBox = PhotoFocus.face(fromHead: head)
            #expect(shown.minY <= faceBox.minY + 0.0001 && shown.maxY >= faceBox.maxY - 0.0001, "face out of view")
        }
        return p
    }

    @Test(arguments: banners)
    func centeredPortraitMovesRight(banner: CGSize) {
        // Olivia Rodrigo's demo photo: a big centered head, square, 1000 px.
        let focus = PhotoFocus(aspect: 1, subject: CGRect(x: 0.371, y: 0.256, width: 0.241, height: 0.385),
                               primary: CGRect(x: 0.371, y: 0.256, width: 0.241, height: 0.385), source: .face, sourceWidth: 1000)
        let p = check(focus, banner: banner)
        // It can't zoom far enough to fill the leading edge without cutting the face, so the edge fill takes over there.
        #expect(p.origin.x > 0)
        // Chin above the heavy part of the fade.
        let chin = (p.origin.y + PhotoFocus.face(fromHead: focus.subject!).maxY * p.size.height) / banner.height
        #expect(chin <= PhotoFocus.clearHeight + 0.001)
    }

    @Test(arguments: banners)
    func faceAlreadyOnTheRightFillsTheBanner(banner: CGSize) {
        // Zach Bryan's: a small face at 0.66 across.
        let p = check(face(CGRect(x: 0.6, y: 0.25, width: 0.12, height: 0.12)), banner: banner)
        #expect(abs(p.origin.x) < 0.5 || p.origin.x < 0)
    }

    @Test(arguments: banners)
    func smallFaceOnTheLeftZoomsWithinTheCap(banner: CGSize) {
        // Billie Eilish's: a small face left of center.
        _ = check(face(CGRect(x: 0.245, y: 0.4, width: 0.097, height: 0.097)), banner: banner)
    }

    @Test
    func largeSourceZoomsAllTheWay() {
        // A 3000 px photo has room: the face reaches the target with the leading edge filled by the photo itself.
        let p = check(face(CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.1), sourceWidth: 3000), banner: Self.banners[0])
        #expect(p.origin.x <= 0.5)
    }

    @Test
    func wholeFacePhotoStillCoversTheBanner() {
        // The Weeknd's: the face fills the photo. It can't fit above the fade; it still covers the banner.
        let focus = PhotoFocus(aspect: 1, subject: CGRect(x: 0.16, y: 0.017, width: 0.66, height: 0.98), primary: nil, source: .face, sourceWidth: 1000)
        let p = focus.placement(banner: Self.banners[0], displayScale: 2)
        #expect(p.origin.y <= 0 && p.origin.y + p.size.height >= Self.banners[0].height - 0.001)
        #expect(p.origin.x + p.size.width >= Self.banners[0].width - 0.001)
    }

    @Test
    func nothingFoundUsesTheOldVerticalCrop() {
        let focus = PhotoFocus(aspect: 1, subject: nil, primary: nil, source: .none)
        let banner = Self.banners[0]
        let p = focus.placement(banner: banner)
        let shown = p.visibleRect(banner: banner)
        #expect(abs(shown.minY - PhotoFocus.defaultFocusY * (1 - shown.height)) < 0.001)
    }

    @Test
    func saliencyCentersTheRegionVertically() {
        let focus = PhotoFocus(aspect: 1, subject: CGRect(x: 0.5, y: 0.6, width: 0.3, height: 0.2), primary: nil, source: .saliency)
        let banner = Self.banners[0]
        let shown = focus.placement(banner: banner).visibleRect(banner: banner)
        #expect(abs(shown.midY - 0.7) < 0.0001)
    }

    @Test
    func faceAtTheTopStaysInsideThePhoto() {
        let focus = face(CGRect(x: 0.4, y: 0.0, width: 0.1, height: 0.1))
        let banner = Self.banners[0]
        let shown = focus.placement(banner: banner).visibleRect(banner: banner)
        #expect(shown.minY >= 0 && shown.maxY <= 1.0001)
    }

    @Test
    func faceFromHeadInvertsHead() {
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let back = PhotoFocus.face(fromHead: PhotoFocus.head(fromFace: face))
        #expect(abs(back.minY - face.minY) < 0.0001 && abs(back.height - face.height) < 0.0001)
    }

    @Test
    func scrimForWhiteText() {
        // Dark enough already: nothing needed.
        #expect(PhotoFocus.scrimForWhiteText(over: 0.1) == 0)
        // White under the name: black 0.6 brings it to about 5.6:1 (4.5:1 with room for a cell's bright spots).
        let alpha = PhotoFocus.scrimForWhiteText(over: 1)
        #expect(abs(alpha - 0.6) < 0.01)
        // Check the result: white over gray (1 − alpha) is 4.5:1.
        let g = 1 - alpha
        let lum = pow((g + 0.055) / 1.055, 2.4)
        #expect((1.05 / (lum + 0.05)) >= 4.5)
        // A darkening already applied (dark mode's 0.3 over a pale photo) counts.
        #expect(PhotoFocus.scrimForWhiteText(over: 1, extraDarkening: 0.3) < alpha)
    }

    @Test
    func brightestToneReadsTheCellsUnderTheText() {
        var focus = PhotoFocus(aspect: 1, subject: nil, primary: nil, source: .none)
        let n = PhotoFocus.toneGrid
        // Dark everywhere except the bottom-left cell.
        focus.tones = (0..<(n * n)).map { $0 == (n - 1) * n ? 0.9 : 0.05 }
        let placement = HeroPhotoPlacement(size: CGSize(width: 1000, height: 1000), origin: .zero)
        #expect(focus.brightestTone(in: CGRect(x: 0, y: 980, width: 30, height: 15), placement: placement) == Double(Float(0.9)))
        #expect(focus.brightestTone(in: CGRect(x: 500, y: 100, width: 30, height: 15), placement: placement) == Double(Float(0.05)))
        // Left of the photo reads its leftmost column.
        let shifted = HeroPhotoPlacement(size: CGSize(width: 1000, height: 1000), origin: CGPoint(x: 300, y: 0))
        #expect(focus.brightestTone(in: CGRect(x: 10, y: 980, width: 30, height: 15), placement: shifted) == Double(Float(0.9)))
    }
}
