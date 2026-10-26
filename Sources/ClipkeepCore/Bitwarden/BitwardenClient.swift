import Foundation

public enum BitwardenStatus: Sendable, Equatable {
    case loggedOut
    case locked
    case unlocked
}

/// Why a Bitwarden call failed. None of the cases carries output of the command, which may
/// contain secrets.
public enum BitwardenError: Error, Equatable, Sendable {
    case notInstalled
    case loggedOut
    case locked
    case invalidMasterPassword
    case offline
    case timedOut
    case unexpectedOutput
    case commandFailed
    /// A transfer is already running.
    case busy
}

/// A secure note as stored in the vault.
public struct BitwardenNote: Sendable, Equatable {
    public let id: String
    public let notes: String?
    /// Identifies the parked secret the note was made from.
    public let clipkeepID: String?
}

public protocol BitwardenClient: Sendable {
    func status(session: String?) async throws -> BitwardenStatus
    /// Unlocks the vault and returns the session key.
    func unlock(masterPassword: String) async throws -> String
    func lock(session: String) async throws
    /// Fetches the latest vault state from the server; fails when it cannot be reached.
    func sync(session: String) async throws
    /// The folder with this name; created when missing.
    func folderID(named name: String, session: String) async throws -> String
    func createSecureNote(
        name: String, secret: String, clipkeepID: String, folderID: String, session: String
    ) async throws -> BitwardenNote
    func notes(inFolder folderID: String, session: String) async throws -> [BitwardenNote]
}

/// Talks to the Bitwarden CLI (`bw`).
public struct BitwardenCLIClient: BitwardenClient {
    static let passwordVariable = "CLIPKEEP_BW_PASSWORD"
    static let markerFieldName = "clipkeep-id"

    private let runner: any CommandRunning
    /// `bw` keeps its state in one file, so only one command runs at a time.
    private let gate = CommandGate()

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func status(session: String?) async throws -> BitwardenStatus {
        let output = try await run(["status"], session: session)
        guard let data = output.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(StatusResponse.self, from: data)
        else { throw BitwardenError.unexpectedOutput }
        switch decoded.status {
        case "unauthenticated": return .loggedOut
        case "locked": return .locked
        case "unlocked": return .unlocked
        default: throw BitwardenError.unexpectedOutput
        }
    }

    public func unlock(masterPassword: String) async throws -> String {
        // The password travels in the environment of this one command, not in its arguments or on
        // disk. Other processes of the same user can still read a process's environment.
        let output = try await run(
            ["unlock", "--passwordenv", Self.passwordVariable, "--raw"], session: nil,
            extraEnvironment: [Self.passwordVariable: masterPassword])
        let key = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A single token; an update notice or other extra output is not a key.
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            throw BitwardenError.unexpectedOutput
        }
        return key
    }

    public func lock(session: String) async throws {
        _ = try await run(["lock"], session: session)
    }

    public func sync(session: String) async throws {
        _ = try await run(["sync"], session: session)
    }

    public func folderID(named name: String, session: String) async throws -> String {
        let listed = try await run(["list", "folders", "--search", name], session: session)
        let folders = try decode([FolderResponse].self, from: listed)
        if let match = folders.first(where: { $0.name == name }) { return match.id }
        let created = try await run(
            ["create", "folder"], session: session, standardInput: Self.encoded(["name": name]))
        return try decode(FolderResponse.self, from: created).id
    }

    public func createSecureNote(
        name: String, secret: String, clipkeepID: String, folderID: String, session: String
    ) async throws -> BitwardenNote {
        let item = NewItem(
            name: name, notes: secret, folderId: folderID,
            fields: [NewItem.Field(name: Self.markerFieldName, value: clipkeepID)])
        guard let json = try? JSONEncoder().encode(item) else {
            throw BitwardenError.unexpectedOutput
        }
        // The secret travels on standard input, not in the arguments.
        let created = try await run(
            ["create", "item"], session: session,
            standardInput: json.base64EncodedString())
        return try decode(ItemResponse.self, from: created).note
    }

    public func notes(inFolder folderID: String, session: String) async throws -> [BitwardenNote] {
        let listed = try await run(["list", "items", "--folderid", folderID], session: session)
        return try decode([ItemResponse].self, from: listed).map(\.note)
    }

    // MARK: - Running

    private func run(
        _ arguments: [String], session: String?, extraEnvironment: [String: String] = [:],
        standardInput: String? = nil
    ) async throws -> String {
        var environment = extraEnvironment
        if let session { environment["BW_SESSION"] = session }
        let outcome: Result<CommandResult, Error>
        await gate.acquire()
        do {
            outcome = .success(
                try await runner.run(
                    arguments: arguments, environment: environment, standardInput: standardInput))
        } catch {
            outcome = .failure(error)
        }
        await gate.release()
        let result: CommandResult
        switch outcome {
        case .success(let value): result = value
        case .failure(CommandError.notFound): throw BitwardenError.notInstalled
        case .failure(CommandError.timedOut): throw BitwardenError.timedOut
        case .failure: throw BitwardenError.commandFailed
        }
        guard result.exitCode == 0 else { throw Self.classify(errorOutput: result.standardError) }
        return result.standardOutput
    }

    /// Maps what `bw` printed to an error. The text itself is dropped.
    static func classify(errorOutput: String) -> BitwardenError {
        let text = errorOutput.lowercased()
        if text.contains("invalid master password") { return .invalidMasterPassword }
        if text.contains("not logged in") { return .loggedOut }
        if text.contains("vault is locked") || text.contains("invalid session")
            || text.contains("session key")
        {
            return .locked
        }
        let networkMarkers = [
            "enotfound", "econnrefused", "econnreset", "etimedout", "eai_again", "enetunreach",
            "fetch failed", "failed to fetch", "network", "getaddrinfo", "socket hang up",
        ]
        if networkMarkers.contains(where: text.contains) { return .offline }
        return .commandFailed
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from output: String) throws -> Value {
        guard let data = output.data(using: .utf8),
            let value = try? JSONDecoder().decode(type, from: data)
        else { throw BitwardenError.unexpectedOutput }
        return value
    }

    /// `bw create` takes its JSON base64-encoded.
    private static func encoded(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return data.base64EncodedString()
    }

    // MARK: - Wire format

    private struct StatusResponse: Decodable { let status: String }
    private struct FolderResponse: Decodable {
        let id: String
        let name: String?
    }

    private struct ItemResponse: Decodable {
        struct Field: Decodable {
            let name: String?
            let value: String?
        }
        let id: String
        let notes: String?
        let fields: [Field]?

        var note: BitwardenNote {
            BitwardenNote(
                id: id, notes: notes,
                clipkeepID: fields?.first { $0.name == BitwardenCLIClient.markerFieldName }?.value)
        }
    }

    /// A secure note (type 2) with a text field that marks it as ours.
    private struct NewItem: Encodable {
        struct Field: Encodable {
            let name: String
            let value: String
            let type = 0
        }
        struct SecureNote: Encodable { let type = 0 }
        let type = 2
        let secureNote = SecureNote()
        let name: String
        let notes: String
        let folderId: String
        let fields: [Field]
    }
}

/// Lets one caller at a time through, in the order they arrived.
private actor CommandGate {
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isBusy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isBusy = true
        }
    }

    func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
