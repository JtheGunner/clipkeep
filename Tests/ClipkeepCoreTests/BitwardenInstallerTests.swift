import Foundation
import Testing

@testable import ClipkeepCore

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(arguments: [String], environment: [String: String])] = []
    private let outcome: Result<CommandResult, CommandError>

    init(_ outcome: Result<CommandResult, CommandError>) { self.outcome = outcome }

    var calls: [(arguments: [String], environment: [String: String])] {
        lock.withLock { recorded }
    }

    func run(
        arguments: [String], environment: [String: String], standardInput: String?
    ) async throws -> CommandResult {
        lock.withLock { recorded.append((arguments, environment)) }
        return try outcome.get()
    }
}

private func exit(_ code: Int32, error: String = "") -> Result<CommandResult, CommandError> {
    .success(CommandResult(exitCode: code, standardOutput: "", standardError: error))
}

@Suite struct BitwardenInstallerTests {
    @Test func installsThroughHomebrewWithoutAnUpdateOrPrompt() async throws {
        let runner = RecordingRunner(exit(0))
        let installer = HomebrewBitwardenInstaller(runner: runner, isAvailable: { true })
        try await installer.install()
        let call = try #require(runner.calls.first)
        #expect(call.arguments == ["install", "bitwarden-cli"])
        #expect(call.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(call.environment["NONINTERACTIVE"] == "1")
    }

    @Test func isAvailableOnlyWhenHomebrewIsThere() {
        let runner = RecordingRunner(exit(0))
        #expect(HomebrewBitwardenInstaller(runner: runner, isAvailable: { true }).isAvailable)
        #expect(!HomebrewBitwardenInstaller(runner: runner, isAvailable: { false }).isAvailable)
    }

    @Test func aMissingHomebrewIsNotAvailableOnDisk() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-nobrew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(!HomebrewBitwardenInstaller(searchDirectories: [empty.path]).isAvailable)
    }

    @Test func aFailingInstallIsReportedWithoutTheCommandOutput() async {
        let runner = RecordingRunner(exit(1, error: "Error: /opt/homebrew/secret-path failed"))
        let installer = HomebrewBitwardenInstaller(runner: runner, isAvailable: { true })
        await #expect(throws: BitwardenInstallError.failed) { try await installer.install() }
    }

    @Test func aLaunchFailureCountsAsFailed() async {
        let runner = RecordingRunner(.failure(.launchFailed))
        let installer = HomebrewBitwardenInstaller(runner: runner, isAvailable: { true })
        await #expect(throws: BitwardenInstallError.failed) { try await installer.install() }
    }

    @Test func aMissingHomebrewAtRunTimeCountsAsFailed() async {
        let runner = RecordingRunner(.failure(.notFound))
        let installer = HomebrewBitwardenInstaller(runner: runner, isAvailable: { true })
        await #expect(throws: BitwardenInstallError.failed) { try await installer.install() }
    }

    @Test func aTimeoutIsReported() async {
        let runner = RecordingRunner(.failure(.timedOut))
        let installer = HomebrewBitwardenInstaller(runner: runner, isAvailable: { true })
        await #expect(throws: BitwardenInstallError.timedOut) { try await installer.install() }
    }
}
