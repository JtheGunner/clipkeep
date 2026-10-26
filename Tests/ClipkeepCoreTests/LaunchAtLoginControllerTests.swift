import Testing

@testable import ClipkeepCore

private final class FakeLoginItemService: LoginItemService, @unchecked Sendable {
    struct Failure: Error {}

    var isEnabled = false
    var shouldFail = false

    func setEnabled(_ enabled: Bool) throws {
        if shouldFail { throw Failure() }
        isEnabled = enabled
    }
}

@MainActor
@Suite struct LaunchAtLoginControllerTests {
    @Test func toggleEnablesWhenDisabled() {
        let service = FakeLoginItemService()
        let controller = LaunchAtLoginController(service: service)

        controller.toggle()

        #expect(service.isEnabled)
        #expect(controller.errorMessage == nil)
    }

    @Test func toggleDisablesWhenEnabled() {
        let service = FakeLoginItemService()
        service.isEnabled = true
        let controller = LaunchAtLoginController(service: service)

        controller.toggle()

        #expect(!service.isEnabled)
    }

    @Test func failureSetsMessageAndKeepsState() {
        let service = FakeLoginItemService()
        service.shouldFail = true
        let controller = LaunchAtLoginController(service: service)

        controller.toggle()

        #expect(!service.isEnabled)
        #expect(controller.errorMessage != nil)
    }

    @Test func successClearsEarlierMessage() {
        let service = FakeLoginItemService()
        service.shouldFail = true
        let controller = LaunchAtLoginController(service: service)
        controller.toggle()

        service.shouldFail = false
        controller.toggle()

        #expect(controller.errorMessage == nil)
        #expect(service.isEnabled)
    }
}
