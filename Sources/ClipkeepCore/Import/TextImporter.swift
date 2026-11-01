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
    /// UTF-8 size of the entries counted in `secretCount`.
    public let secretBytes: Int
    /// UTF-8 size of all entries.
    public let totalBytes: Int
    /// Date headings found in the text; 0 means every block becomes a session of its own.
    public let headingCount: Int

    /// From this share of the text on, entries dropped because of a secret deserve a warning.
    public static let largeSecretShare = 0.2

    /// Share of the text that goes away together with the entries that contain a secret.
    public var secretShare: Double {
        totalBytes > 0 ? Double(secretBytes) / Double(totalBytes) : 0
    }

    /// True when secrets take a large part of the text with them, as happens when a long block
    /// holds a single secret.
    public var warnsAboutSecretBlocks: Bool {
        secretCount > 0 && secretShare >= Self.largeSecretShare
    }
}

public struct ImportReport: Sendable, Equatable {
    public var imported = 0
    public var duplicates = 0
    /// Detected secrets that went to the vault (or were dropped when there is no vault).
    public var secrets = 0
    /// Detected secrets that could not be stored in the vault; they are in neither place.
    public var secretsFailed = 0
    public var skipped = 0
    public var wasCancelled = false
    /// Date headings the entries were dated with; 0 means every block became its own session.
    public var headingCount = 0
}

/// Imports a collected text document (for example years of notes in one file) into the history.
///
/// Every entry goes through the same checks as a live copy: length limits, the secret detector
/// (secrets go to the `SecretSink`, or are dropped when there is none, never into the database),
/// exact duplicate detection and the classifier. Entries get the source "Import" and no live
/// context. Running the same import again adds nothing.
///
/// A text file has no timestamps, so the entries are dated by its structure: entries under a date
/// heading get that day (see `DateHeading`). A file without such headings gets one session per
/// block, `blockSpacing` apart, ending at the file date.
public struct TextImporter: Sendable {
    public static let importBundleID = "li.wuermli.clipkeep.import"
    public static let maximumFileBytes = 200_000_000
    private static let pauseBeforeLive: TimeInterval = 3_600
    /// Distance between blocks of a file without date headings: just over the pause that ends a
    /// session, so every block is a session of its own.
    static let blockSpacing = SessionConfiguration.default.gap + 300

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
        // Open first and judge the open file, so a path swapped after a check (a FIFO, say)
        // cannot hang the read. Symlinks to regular files are followed.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard status.st_size <= maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
        // At most one byte past the limit, so a file that grew since the check is caught.
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
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
        let dated = TextSplitter.splitDated(text, mode: mode)
        let entries = dated.entries.map(\.text)
        var secrets = 0
        var stored = 0
        var tooShort = 0
        var tooLong = 0
        var secretBytes = 0
        var totalBytes = 0
        var seen = Set<String>()
        for entry in entries {
            if isCancelled() { throw CancellationError() }
            totalBytes += entry.utf8.count
            let skip = CaptureStages.lengthSkip(of: entry, configuration: configuration)
            if skip == .tooShort { tooShort += 1 }
            if skip == .tooLong { tooLong += 1 }
            guard skip == nil else { continue }
            if isSecret(entry) {
                if secretSink?.isParked(entry) == true {
                    stored += 1
                } else {
                    secrets += 1
                    secretBytes += entry.utf8.count
                }
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
            tooShortCount: tooShort, tooLongCount: tooLong,
            secretBytes: secretBytes, totalBytes: totalBytes, headingCount: dated.headingCount)
    }

    /// - Parameters:
    ///   - endingAt: the latest time an entry may get. Without date headings the last entry
    ///     ends there and earlier blocks lie `blockSpacing` before each other; with headings no
    ///     entry lies after it.
    ///   - progress: called with (done, total) every few entries.
    ///   - isCancelled: checked between entries.
    public func run(
        text: String, mode: SplitMode = .automatic, source: String, endingAt: Date,
        progress: @Sendable (Int, Int) -> Void = { _, _ in },
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> ImportReport {
        let dated = TextSplitter.splitDated(text, mode: mode)
        let entries = dated.entries.map(\.text)
        let context = CopyContext(
            appBundleID: Self.importBundleID, appName: "Import", windowTitle: source)
        var report = ImportReport()
        report.headingCount = dated.headingCount
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
        let times = Self.times(for: dated.entries, endingAt: end)
        defer { _ = try? sessions.rebuild() }
        for (index, entry) in entries.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            if index % 200 == 0 { progress(index, entries.count) }
            let time = times[index]
            if CaptureStages.lengthSkip(of: entry, configuration: configuration) != nil {
                report.skipped += 1
            } else if isSecret(entry) {
                if secretSink?.isParked(entry) == true {
                    report.duplicates += 1
                } else {
                    let stored = secretSink?.park(secret: entry, context: context, copiedAt: time)
                    if stored == false { report.secretsFailed += 1 } else { report.secrets += 1 }
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

    /// One time per entry, in file order. Under a heading the entries follow one second apart from
    /// the heading's moment; without headings each block gets its own session.
    static func times(for entries: [TextSplitter.DatedEntry], endingAt end: Date) -> [Date] {
        guard entries.first?.heading != nil else {
            return entries.indices.map { index in
                end.addingTimeInterval(-Double(entries.count - 1 - index) * blockSpacing)
            }
        }
        var times: [Date] = []
        var previous: DateHeading?
        var offset = 0.0
        for entry in entries {
            offset = entry.heading == previous ? offset + 1 : 0
            previous = entry.heading
            let moment = entry.heading?.date ?? end
            times.append(min(moment.addingTimeInterval(offset), end))
        }
        return times
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
