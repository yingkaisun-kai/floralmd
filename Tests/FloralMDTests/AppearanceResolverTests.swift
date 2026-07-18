import AppKit
import Testing
@testable import FloralMDCore

@Suite("AppearanceResolver")
struct AppearanceResolverTests {
    @MainActor
    @Test func resolvesCanonicalLightAndDarkAppearances() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        #expect(AppearanceResolver.isDark(light) == false)
        #expect(AppearanceResolver.isDark(dark))
    }
}
