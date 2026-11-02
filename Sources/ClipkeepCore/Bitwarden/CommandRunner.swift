import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum CommandError: Error, Equatable {
    case notFound
    case launchFailed
    case timedOut
}

/// Runs an external command. Secrets go in through `standardInput` or `environment`, never
/// through the arguments, which every process of the user can read.
public protocol CommandRunning: Sendable {
    func run(
        arguments: [String], environment: [String: String], standardInput: String?
    ) async throws -> CommandResult
}

/// Runs one executable found on disk. The command is looked up on every call, so installing it
/// while the app runs works without a restart.
public struct ProcessCommandRunner: CommandRunning {
    /// Menu bar apps start with a minimal PATH, so the usual install locations are added.
    public static let defaultSearchDirectories: [String] = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map(String.init) + [
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
    }()

    /// Variables the command may inherit. Everything else, notably any `BW_SESSION`, is dropped.
    private static let inheritedVariables: Set<String> = [
        "HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
        "https_proxy", "http_proxy", "no_proxy", "NODE_EXTRA_CA_CERTS",
    ]

    private let executableName: String
    private let searchDirectories: [String]
    private let timeout: TimeInterval

    public init(
        executableName: String = "bw", searchDirectories: [String] = defaultSearchDirectories,
        timeout: TimeInterval = 60
    ) {
        self.executableName = executableName
        self.searchDirectories = searchDirectories
        self.timeout = timeout
    }

    /// The executable's location, or nil when it is not installed.
    public func locate() -> URL? {
        searchDirectories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executableName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func run(
        arguments: [String], environment: [String: String], standardInput: String?
    ) async throws -> CommandResult {
        guard let executable = locate() else { throw CommandError.notFound }
        let timeout = timeout
        let searchDirectories = searchDirectories
        return try await withCheckedThrowingContinuation { continuation in
            // A dedicated thread: the shared dispatch pool can be saturated by other blocking
            // work, which would delay the start and with it the timeout of this command.
            let thread = Thread {
                continuation.resume(
                    with: Result {
                        try Self.runBlocking(
                            executable: executable, arguments: arguments,
                            environment: Self.childEnvironment(
                                adding: environment, searchDirectories: searchDirectories),
                            standardInput: standardInput, timeout: timeout)
                    })
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private static func childEnvironment(
        adding extra: [String: String], searchDirectories: [String]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter {
            inheritedVariables.contains($0.key) || $0.key.hasPrefix("BITWARDENCLI_")
        }
        // `bw` is a Node script that finds `node` through PATH.
        environment["PATH"] = (searchDirectories + ["/usr/bin", "/bin"]).joined(separator: ":")
        // The command must never wait for a prompt nobody can answer.
        environment["BW_NOINTERACTION"] = "true"
        return environment.merging(extra) { _, new in new }
    }

    private static func runBlocking(
        executable: URL, arguments: [String], environment: [String: String],
        standardInput: String?, timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A command that exits early must not kill this app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed
        }

        let timedOut = Flag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            // A child that ignores SIGTERM is killed after a short grace period.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let standardOutput = Collected()
        let standardError = Collected()
        let group = DispatchGroup()
        for (handle, store) in [
            (output.fileHandleForReading, standardOutput),
            (errors.fileHandleForReading, standardError),
        ] {
            group.enter()
            DispatchQueue.global().async {
                store.data = (try? handle.readToEnd()) ?? Data()
                group.leave()
            }
        }
        if let standardInput {
            try? input.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8))
        }
        try? input.fileHandleForWriting.close()
        // A grandchild may keep the pipes open after the child is gone; the call still ends.
        let drained = group.wait(timeout: .now() + timeout + 3)
        watchdog.cancel()
        if drained == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CommandError.timedOut
        }
        process.waitUntilExit()

        if timedOut.isSet { throw CommandError.timedOut }
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: standardOutput.data, as: UTF8.self),
            standardError: String(decoding: standardError.data, as: UTF8.self))
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var data: Data {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
