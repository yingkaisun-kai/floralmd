import AppKit
import Testing
@testable import FloralMDCore

@MainActor
struct RemoteImageRenderCacheTests {
    @Test("Remote images remain strongly cached for later restyles")
    func retainsFetchedImage() {
        let cache = RemoteImageRenderCache()
        let image = NSImage(size: NSSize(width: 8, height: 8))

        cache.insert(image, for: "https://example.com/badge.png")

        #expect(cache.image(for: "https://example.com/badge.png") === image)
        #expect(cache.image(for: "https://example.com/other.png") == nil)
    }
}
