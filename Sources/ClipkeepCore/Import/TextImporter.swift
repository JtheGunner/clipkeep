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
    private static let pauseBeforeLive: TimeInterval = 3_600

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

    /// Reads a text file: UTF-8, UTF-16 with a byte order mark, else Windows-1252. Binary files
    /// (NUL bytes) and files over the size limit are refused.
    public static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> String {
        let hasUTF16Mark = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if hasUTF16Mark, let text = String(data: data, encoding: .utf16) { return text }
        guard !data.prefix(8_192).contains(0) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    public func preview(
        text: String, mode: SplitMode = .automatic, isCancelled: @Sendable () -> Bool = { false }
    ) throws -> ImportPreview {
        let entries = TextSplitter.split(text, mode: mode)
        var secrets = 0
        var stored = 0
        var tooShort = 0
        var tooLong = 0
        var seen = Set<String>()
        for entry in entries {
            if isCancelled() { throw CancellationError() }
            let skip = CaptureStages.lengthSkip(of: entry, configuration: configuration)
            if skip == .tooShort { tooShort += 1 }
            if skip == .tooLong { tooLong += 1 }
            guard skip == nil else { continue }
            if isSecret(entry) {
                if secretSink?.isParked(entry) == true { stored += 1 } else { secrets += 1 }
            } else if try !seen.insert(ContentHashing.exactHash(entry)).inserted || isStored(entry)
            {
                stored += 1
            }
        }
        // Samples never show text that looks like a secret, whatever happened to the entry.
        let samples = entries.prefix(ImportPreview.sampleSize).map { entry in
            detector.containsSecret(in: entry)
                ? "(Secret – wird nicht angezeigt)" : Self.sample(entry)
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
        // The old entries go before everything captured live, with a pause to the first of those,
        // so they never merge into a real session.
        let oldest = try database.read { connection in
            try connection.query("SELECT min(copied_at) FROM copy_events") {
                $0.isNull(0) ? nil : $0.double(0)
            }.first ?? nil
        }
        var end = endingAt
        if let oldest, oldest - Self.pauseBeforeLive < end.timeIntervalSince1970 {
            end = Date(timeIntervalSince1970: oldest - Self.pauseBeforeLive)
        }
        let start = end.addingTimeInterval(-Double(entries.count))
        defer { _ = try? sessions.rebuild() }
        for (index, entry) in entries.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            if index % 200 == 0 { progress(index, entries.count) }
            let time = start.addingTimeInterval(Double(index + 1))
            if CaptureStages.lengthSkip(of: entry, configuration: configuration) != nil {
                report.skipped += 1
            } else if isSecret(entry) {
                if secretSink?.isParked(entry) == true {
                    report.duplicates += 1
                } else {
                    report.secrets += 1
                    secretSink?.handle(secret: entry, context: context, copiedAt: time)
                }
            } else if try isStored(entry) {
                report.duplicates += 1
            } else {
                _ = try store.record(text: entry, copiedAt: time, context: context)
                report.imported += 1
            }
        }
        progress(entries.count, entries.count)
        return report
    }

    private func isSecret(_ text: String) -> Bool {
        detector.containsSecret(in: text) && !isException(text)
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
