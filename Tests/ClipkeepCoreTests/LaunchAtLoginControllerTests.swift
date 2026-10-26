import Testing

@testable import ClipkeepCore

private final class FakeLoginItemService: LoginItemService, @unchecked Sendable {
    struct Failure: Error {}

    var status: LoginItemStatus = .disabled
    var shouldFail = false
    var isEnabled: Bool {
        get { status == .enabled }
        set { status = newValue ? .enabled : .disabled }
    }

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

    @Test func pendingApprovalShowsHintAndToggleUnregisters() {
        let service = FakeLoginItemService()
        service.status = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        #expect(!controller.isEnabled)
        #expect(controller.errorMessage != nil)

        controller.toggle()

        #expect(service.status == .disabled)
        #expect(controller.errorMessage == nil)
    }
}
