import Testing

@testable import ClipkeepCore

@Suite struct AppInfoTests {
    @Test func bundleIdentifierIsReverseDomain() {
        #expect(AppInfo.bundleIdentifier.split(separator: ".").count >= 3)
    }

    @Test func nameIsNotEmpty() {
        #expect(!AppInfo.name.isEmpty)
    }
}
