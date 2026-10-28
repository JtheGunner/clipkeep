import Testing

@testable import ClipkeepCore

private struct FakePasteboardAccessProvider: PasteboardAccessProvider {
    let access: PasteboardAccess
    func current() -> PasteboardAccess { access }
}

@Suite struct PasteboardAccessTests {
    @Test func restrictedStatesNeedAHint() {
        #expect(PasteboardAccess.askEachTime.needsHint)
        #expect(PasteboardAccess.denied.needsHint)
    }

    @Test func allowedAndUnknownStatesNeedNoHint() {
        #expect(!PasteboardAccess.allowed.needsHint)
        #expect(!PasteboardAccess.unknown.needsHint)
    }

    @Test func hintExistsExactlyWhenNeeded() {
        for access in [PasteboardAccess.allowed, .askEachTime, .denied, .unknown] {
            #expect((access.hint != nil) == access.needsHint)
        }
    }

    @Test func hintsDifferBetweenAskAndDeny() {
        #expect(PasteboardAccess.askEachTime.hint != PasteboardAccess.denied.hint)
    }

    @Test func providerIsReplaceable() {
        let provider: any PasteboardAccessProvider = FakePasteboardAccessProvider(access: .denied)
        #expect(provider.current() == .denied)
    }

    @Test func systemProviderAnswersWithoutCrashing() {
        _ = SystemPasteboardAccessProvider().current()
    }
}
