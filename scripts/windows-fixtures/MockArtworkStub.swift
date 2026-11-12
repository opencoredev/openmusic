import Foundation
// Linux stand-in for Sources/OpenMusicCore/Mock/MockArtwork.swift (which draws with CoreGraphics): only the URL helpers
// the catalogs use. fnv1a and SeededRandom are appended from the real file by generate.sh.
public enum MockArtwork {
    public static let scheme = "openmusic-mock"
    public static func url(_ kind: String, _ seed: String) -> URL? { URL(string: "\(scheme)://\(kind)/\(seed)") }
    public static func artwork(_ kind: String, _ seed: String) -> Artwork? {
        guard let url = url(kind, seed) else { return nil }
        return Artwork(images: [ArtworkImage(url: url, width: 1200, height: 1200)])
    }
}
