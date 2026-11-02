import Foundation

/// Why installing the Bitwarden CLI failed. Neither case carries output of the command.
public enum BitwardenInstallError: Error, Equatable, Sendable {
    case failed
    case timedOut
}

public protocol BitwardenInstalling: Sendable {
    /// Whether an installation can be offered at all.
    var isAvailable: Bool { get }
    func install() async throws
}

/// Installs the Bitwarden CLI with Homebrew. Not available without Homebrew: nothing else is
/// downloaded or run in its place.
public struct HomebrewBitwardenInstaller: BitwardenInstalling {
    static let formula = "bitwarden-cli"

    private let runner: any CommandRunning
    private let locateHomebrew: @Sendable () -> Bool

    public init(searchDirectories: [String] = ProcessCommandRunner.defaultSearchDirectories) {
        let runner = ProcessCommandRunner(
            executableName: "brew", searchDirectories: searchDirectories, timeout: 600)
        self.runner = runner
        locateHomebrew = { runner.locate() != nil }
    }

    init(runner: any CommandRunning, isAvailable: @escaping @Sendable () -> Bool) {
        self.runner = runner
        locateHomebrew = isAvailable
    }

    public var isAvailable: Bool { locateHomebrew() }

    public func install() async throws {
        let result: CommandResult
        do {
            result = try await runner.run(
                arguments: ["install", Self.formula],
                // No update of all formulae first, and no prompt nobody can answer.
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1"],
                standardInput: nil)
        } catch CommandError.timedOut {
            throw BitwardenInstallError.timedOut
        } catch {
            throw BitwardenInstallError.failed
        }
        guard result.exitCode == 0 else { throw BitwardenInstallError.failed }
    }
}
