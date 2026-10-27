import Foundation

public struct ImportPreview: Sendable, Equatable {
    public static let sampleSize = 20

    /// The mode `automatic` resolved to.
    public let mode: SplitMode
    public let entryCount: Int
    /// The first entries, each cut to a few lines. Entries that look like secrets show a
    /// placeholder instead of their text.
    public let samples: [String]
    public let secretCount: Int
    public let alreadyStoredCount: Int
    public let tooShortCount: Int
    public let tooLongCount: Int
}

public struct ImportReport: Sendable, Equatable {
    public var imported = 0
    public var duplicates = 0
    /// Detected secrets that went to the vault (or were dropped when there is no vault).
    public var secrets = 0
    public var skipped = 0
    public var wasCancelled = false
}

/// Imports a collected text document (for example years of notes in one file) into the history.
///
/// Every entry goes through the same checks as a live copy: length limits, the secret detector
/// (secrets go to the `SecretSink`, or are dropped when there is none, never into the database),
/// exact duplicate detection and the classifier. Entries get the source "Import" and no live
/// context. Running the same import again adds nothing.
public struct TextImporter: Sendable {
    public static let importBundleID = "li.wuermli.clipkeep.import"
    public static let maximumFileBytes = 200_000_000

    private let database: Database
    private let store: ContentStore
    private let detector: SecretDetector
    private let secretSink: (any SecretSink)?
    private let configuration: CaptureConfiguration
    private let sessions: SessionService

    public init(
        database: Database, secretSink: (any SecretSink)?,
        detector: SecretDetector = SecretDetector(),
        configuration: CaptureConfiguration = CaptureConfiguration()
    ) {
        self.database = database
        // Sessions are rebuilt once at the end, not after every entry.
        store = ContentStore(database: database, sessions: nil)
        self.detector = detector
        self.secretSink = secretSink
        self.configuration = configuration
        sessions = SessionService(database: database)
    }

    /// Reads a text file; refuses anything that is not text or is too big.
    public static func read(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }

    public func preview(text: String, mode: SplitMode = .automatic) throws -> ImportPreview {
        let entries = TextSplitter.split(text, mode: mode)
        var secrets = 0
        var stored = 0
        var tooShort = 0
        var tooLong = 0
        var samples: [String] = []
        for entry in entries {
            let skip = CaptureStages.lengthSkip(of: entry, configuration: configuration)
            if skip == .tooShort { tooShort += 1 }
            if skip == .tooLong { tooLong += 1 }
            let isSecret =
                skip == nil && detector.containsSecret(in: entry) && !isException(entry)
            if isSecret { secrets += 1 }
            if skip == nil, !isSecret, try isStored(entry) { stored += 1 }
            if samples.count < ImportPreview.sampleSize {
                samples.append(
                    isSecret ? "(Secret – wird gesichert, nicht importiert)" : Self.sample(entry))
            }
        }
        return ImportPreview(
            mode: TextSplitter.resolve(mode, text: text), entryCount: entries.count,
            samples: samples, secretCount: secrets, alreadyStoredCount: stored,
            tooShortCount: tooShort, tooLongCount: tooLong)
    }

    /// - Parameters:
    ///   - endingAt: time of the last entry; earlier entries follow one second apart in file
    ///     order, which keeps the order of the document.
    ///   - progress: called with (done, total) every few entries.
    ///   - isCancelled: checked between entries.
    public func run(
        text: String, mode: SplitMode = .automatic, source: String, endingAt: Date,
        progress: @Sendable (Int, Int) -> Void = { _, _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> ImportReport {
        let entries = TextSplitter.split(text, mode: mode)
        let context = CopyContext(
            appBundleID: Self.importBundleID, appName: "Import", windowTitle: source)
        var report = ImportReport()
        let start = endingAt.addingTimeInterval(-Double(entries.count))
        for (index, entry) in entries.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            if index % 200 == 0 { progress(index, entries.count) }
            let time = start.addingTimeInterval(Double(index + 1))
            if CaptureStages.lengthSkip(of: entry, configuration: configuration) != nil {
                report.skipped += 1
            } else if detector.containsSecret(in: entry), !isException(entry) {
                report.secrets += 1
                secretSink?.handle(secret: entry, context: context, copiedAt: time)
            } else if try isStored(entry) {
                report.duplicates += 1
            } else {
                _ = try store.record(text: entry, copiedAt: time, context: context)
                report.imported += 1
            }
        }
        // Also after a cancel: whatever was imported needs its sessions.
        _ = try sessions.rebuild()
        progress(entries.count, entries.count)
        return report
    }

    private func isException(_ text: String) -> Bool {
        secretSink?.isException(text) ?? false
    }

    private func isStored(_ text: String) throws -> Bool {
        let hash = ContentHashing.exactHash(text)
        return try database.read { connection in
            try !connection.query("SELECT 1 FROM contents WHERE hash = ?", [.text(hash)]) { _ in 1 }
                .isEmpty
        }
    }

    private static func sample(_ entry: String) -> String {
        let lines = entry.split(separator: "\n", omittingEmptySubsequences: true)
        let shown = lines.prefix(3).map { String($0.prefix(160)) }.joined(separator: "\n")
        return lines.count > 3 ? shown + "\n…" : shown
    }
}
