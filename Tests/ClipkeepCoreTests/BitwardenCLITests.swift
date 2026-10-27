import Foundation
import Testing

@testable import ClipkeepCore

/// A stand-in for the `bw` executable: a shell script that keeps its vault in a directory and
/// records every call, so the tests can check what was passed on the command line.
private struct FakeBitwardenCLI {
    static let masterPassword = "correct horse"
    static let sessionKey = "good-session"

    let directory: URL
    var arguments: URL { directory.appendingPathComponent("argv.log") }
    var environment: URL { directory.appendingPathComponent("env.log") }
    var storedItems: URL { directory.appendingPathComponent("items") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-bw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            DIR="\(directory.path)"
            echo "$*" >> "$DIR/argv.log"
            echo "BW_SESSION=${BW_SESSION-unset} NOINTERACTION=${BW_NOINTERACTION-unset} HOME=${HOME-unset}" >> "$DIR/env.log"
            need_session() { [ "$BW_SESSION" = "\(Self.sessionKey)" ] || { echo "Vault is locked." >&2; exit 1; }; }
            if [ -f "$DIR/offline" ]; then
              case "$1" in sync|create) echo "getaddrinfo ENOTFOUND vault.bitwarden.com" >&2; exit 1;; esac
            fi
            case "$1" in
              status)
                if [ -f "$DIR/loggedout" ]; then echo '{"status":"unauthenticated"}'
                elif [ "$BW_SESSION" = "\(Self.sessionKey)" ]; then echo '{"status":"unlocked"}'
                else echo '{"status":"locked"}'; fi ;;
              unlock)
                if [ "$CLIPKEEP_BW_PASSWORD" = "\(Self.masterPassword)" ]; then printf %s "\(Self.sessionKey)"
                else echo "Invalid master password." >&2; exit 1; fi ;;
              lock) echo "Your vault is locked." ;;
              sync) need_session; echo "Syncing complete." ;;
              hang) sleep 30 ;;
              list)
                need_session
                if [ "$2" = folders ]; then cat "$DIR/folders.json" 2>/dev/null || echo '[]'
                else
                  printf '['; first=1
                  for f in "$DIR"/items/*.json; do
                    [ -f "$f" ] || continue
                    [ $first = 1 ] || printf ','
                    first=0; cat "$f"
                  done
                  printf ']'
                fi ;;
              create)
                need_session
                payload=$(cat | base64 -D)
                if [ "$2" = folder ]; then
                  echo '[{"id":"folder-1","name":"Clipboard-Secrets"}]' > "$DIR/folders.json"
                  echo '{"id":"folder-1","name":"Clipboard-Secrets"}'
                else
                  mkdir -p "$DIR/items"
                  n=$(ls "$DIR/items" | wc -l | tr -d ' ')
                  item="{\\"id\\":\\"item-$n\\",${payload#\\{}"
                  printf %s "$item" > "$DIR/items/$n.json"
                  printf %s "$item"
                fi ;;
              get)
                need_session
                cat "$DIR/items/${3#item-}.json" 2>/dev/null || { echo "Not found." >&2; exit 1; } ;;
              *) echo "unknown command" >&2; exit 2 ;;
            esac
            """
        let path = directory.appendingPathComponent("bw")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func runner(timeout: TimeInterval = 20) -> ProcessCommandRunner {
        ProcessCommandRunner(searchDirectories: [directory.path], timeout: timeout)
    }

    var client: BitwardenCLIClient { BitwardenCLIClient(runner: runner()) }

    func set(_ flag: String) {
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent(flag).path, contents: Data())
    }

    func log(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class MemoryVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func store(_ secret: String, key: String) throws { lock.withLock { items[key] = secret } }
    func read(key: String) throws -> String? { lock.withLock { items[key] } }
    func delete(key: String) throws { lock.withLock { _ = items.removeValue(forKey: key) } }
    func keys() throws -> [String] { lock.withLock { Array(items.keys) } }
    var parkedCount: Int {
        lock.withLock { items.keys.filter { $0 != SecretParker.fingerprintKeyName }.count }
    }
}

@Suite struct BitwardenCLITests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let context = CopyContext(
        appBundleID: "com.apple.Safari", appName: "Safari", url: "https://console.example.com/keys")
    private var secret: String { "sk-ant-api03-" + String(repeating: "aB3dE6gH9k", count: 8) }
    /// Multi-line, as a private key is.
    private var privateKey: String {
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + String(repeating: "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU", count: 4)
            + "\n-----END OPENSSH PRIVATE KEY-----"
    }

    // MARK: - Status and unlock

    @Test func reportsTheVaultState() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        #expect(try await fake.client.status(session: nil) == .locked)
        #expect(try await fake.client.status(session: FakeBitwardenCLI.sessionKey) == .unlocked)
        fake.set("loggedout")
        #expect(try await fake.client.status(session: nil) == .loggedOut)
    }

    @Test func aMissingCommandIsReportedAsNotInstalled() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-nobw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let client = BitwardenCLIClient(
            runner: ProcessCommandRunner(searchDirectories: [empty.path]))
        await #expect(throws: BitwardenError.notInstalled) {
            try await client.status(session: nil)
        }
    }

    @Test func unlockingReturnsTheSessionKeyAndKeepsThePasswordOffTheCommandLine() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        let key = try await fake.client.unlock(masterPassword: FakeBitwardenCLI.masterPassword)
        #expect(key == FakeBitwardenCLI.sessionKey)
        #expect(!fake.log(fake.arguments).contains(FakeBitwardenCLI.masterPassword))
    }

    @Test func aWrongMasterPasswordIsRecognised() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        await #expect(throws: BitwardenError.invalidMasterPassword) {
            try await fake.client.unlock(masterPassword: "wrong")
        }
    }

    @Test func theCommandNeverWaitsForInput() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        _ = try await fake.client.status(session: nil)
        let environment = fake.log(fake.environment)
        #expect(environment.contains("NOINTERACTION=true"))
        // No session key unless the client was given one.
        #expect(environment.contains("BW_SESSION=unset"))
    }

    @Test func aHangingCommandTimesOut() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        let runner = fake.runner(timeout: 0.5)
        let started = Date()
        await #expect(throws: CommandError.timedOut) {
            try await runner.run(arguments: ["hang"], environment: [:], standardInput: nil)
        }
        // The shell is killed, but its `sleep` keeps the pipes open: the call still ends.
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: - End to end

    private struct Fixture {
        let temp: TemporaryDatabase
        let vault = MemoryVault()
        let parker: SecretParker
        let sync: BitwardenSync

        init(fake: FakeBitwardenCLI) throws {
            temp = try TemporaryDatabase()
            let database = try temp.open()
            parker = SecretParker(
                database: database, store: ContentStore(database: database), vault: vault)
            sync = BitwardenSync(client: fake.client, parker: parker)
        }
    }

    @Test func parkedSecretsEndUpAsSecureNotesWithoutTouchingTheCommandLine() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        let fixture = try Fixture(fake: fake)
        fixture.parker.handle(secret: secret, context: context, copiedAt: base)
        fixture.parker.handle(
            secret: privateKey, context: context, copiedAt: base.addingTimeInterval(5))

        let report = try await fixture.sync.unlock(masterPassword: FakeBitwardenCLI.masterPassword)
        #expect(report == TransferReport(transferred: 2, remaining: 0, failure: nil))
        #expect(fixture.vault.parkedCount == 0)

        // Both notes are in the vault, as secure notes (type 2) in the folder, with the secret.
        let stored = try FileManager.default.contentsOfDirectory(
            at: fake.storedItems, includingPropertiesForKeys: nil)
        let items = try stored.map {
            try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])
        }
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0["type"] as? Int == 2 })
        #expect(items.allSatisfy { $0["folderId"] as? String == "folder-1" })
        #expect(Set(items.compactMap { $0["notes"] as? String }) == [secret, privateKey])

        // The secrets never appeared in an argument.
        let arguments = fake.log(fake.arguments)
        #expect(!arguments.contains(secret))
        #expect(!arguments.contains("BEGIN OPENSSH"))
        #expect(!arguments.contains(FakeBitwardenCLI.masterPassword))
        // The session key was used only through the environment, never as an argument.
        #expect(!arguments.contains(FakeBitwardenCLI.sessionKey))
    }

    @Test func aTransferredSecretComesBackThroughTheCommand() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        let fixture = try Fixture(fake: fake)
        fixture.parker.handle(secret: privateKey, context: context, copiedAt: base)
        let id = try #require(try fixture.parker.pending().first).id
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwardenCLI.masterPassword)
        #expect(try await fixture.sync.retrieve(secretID: id) == privateKey)
        // Fetched by its id, without listing the folder again.
        let calls = try String(contentsOf: fake.arguments, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let direct = try #require(calls.firstIndex(of: "get item item-0"))
        #expect(!calls[direct...].contains { $0.hasPrefix("list items") })
    }

    @Test func offlineKeepsEverythingParked() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        let fixture = try Fixture(fake: fake)
        fixture.parker.handle(secret: secret, context: context, copiedAt: base)
        fake.set("offline")

        let report = try await fixture.sync.unlock(masterPassword: FakeBitwardenCLI.masterPassword)
        #expect(report == TransferReport(transferred: 0, remaining: 1, failure: .offline))
        #expect(fixture.vault.parkedCount == 1)

        // Back online, the next attempt moves it.
        try FileManager.default.removeItem(at: fake.directory.appendingPathComponent("offline"))
        let retry = try await fixture.sync.transferPending()
        #expect(retry == TransferReport(transferred: 1, remaining: 0, failure: nil))
    }

    @Test func aSecondRunDoesNotDuplicateNotes() async throws {
        let fake = try FakeBitwardenCLI()
        defer { fake.remove() }
        let fixture = try Fixture(fake: fake)
        fixture.parker.handle(secret: secret, context: context, copiedAt: base)
        _ = try await fixture.sync.unlock(masterPassword: FakeBitwardenCLI.masterPassword)
        _ = try await fixture.sync.transferPending()
        let stored = try FileManager.default.contentsOfDirectory(
            at: fake.storedItems, includingPropertiesForKeys: nil)
        #expect(stored.count == 1)
    }

    // MARK: - Error classification

    @Test(arguments: [
        ("Invalid master password.", BitwardenError.invalidMasterPassword),
        ("You are not logged in.", .loggedOut),
        ("Vault is locked.", .locked),
        ("Invalid session key", .locked),
        ("request to https://x failed, reason: getaddrinfo ENOTFOUND x", .offline),
        ("FetchError: network timeout", .offline),
        ("connect ECONNREFUSED 127.0.0.1:443", .offline),
        ("Something unrelated broke", .commandFailed),
        ("", .commandFailed),
    ])
    func classifiesWhatTheCommandPrinted(text: String, expected: BitwardenError) {
        #expect(BitwardenCLIClient.classify(errorOutput: text) == expected)
    }
}
