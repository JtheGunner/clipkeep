import Testing

@testable import ClipkeepCore

@Suite struct AppNameResolverTests {
    private let resolver = AppNameResolver { bundleID in
        switch bundleID {
        case "com.apple.TextEdit": "TextEdit"
        case "com.example.blank": "  "
        default: nil
        }
    }

    @Test func anInstalledAppShowsItsName() {
        #expect(resolver.name(for: "com.apple.TextEdit") == "TextEdit")
    }

    @Test func anUnknownAppShowsItsBundleIdentifier() {
        #expect(resolver.name(for: "com.example.gone") == "com.example.gone")
    }

    @Test func aBlankNameFallsBackToTheBundleIdentifier() {
        #expect(resolver.name(for: "com.example.blank") == "com.example.blank")
    }
}
