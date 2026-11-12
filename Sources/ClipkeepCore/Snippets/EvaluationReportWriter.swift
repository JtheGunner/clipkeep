import Foundation

public enum EvaluationReportError: Error, Equatable {
    case insideRepository
    case parentMissing
    case alreadyExists
    case cannotWrite(Int32)
}

/// Writes an evaluation report that contains private clipboard text: never inside the
/// repository, never over an existing file or through a symlink, readable by the owner only.
public enum EvaluationReportWriter {
    /// The nearest directory at or above `directory` that holds `.git` or `Package.swift`.
    public static func repositoryRoot(startingAt directory: URL) -> URL? {
        var current = directory.resolvingSymlinksInPath().standardizedFileURL
        while true {
            for marker in [".git", "Package.swift"]
            where FileManager.default.fileExists(
                atPath: current.appendingPathComponent(marker).path)
            {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// - Parameters:
    ///   - path: a leading `~` is expanded and a relative path is taken from `workingDirectory`.
    ///   - repositoryRoot: where reports are refused; `nil` skips the check.
    public static func write(
        _ text: String, to path: String, repositoryRoot: URL?,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws {
        let target = try resolvedTarget(
            path, repositoryRoot: repositoryRoot, workingDirectory: workingDirectory)
        // O_EXCL fails on an existing file and, with O_CREAT, on a symlink at the path.
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? EvaluationReportError.alreadyExists : .cannotWrite(errno)
        }
        defer { close(descriptor) }
        // Mode 0600 is requested at creation; the umask can only remove bits.
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes {
                Foundation.write(descriptor, $0.baseAddress, $0.count)
            }
            guard written > 0 else { throw EvaluationReportError.cannotWrite(errno) }
            offset += written
        }
    }

    private static func resolvedTarget(
        _ path: String, repositoryRoot: URL?, workingDirectory: URL
    ) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : workingDirectory.appendingPathComponent(expanded)
        let standardized = absolute.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw EvaluationReportError.parentMissing }
        let target = parent.appendingPathComponent(standardized.lastPathComponent)
        if let root = repositoryRoot?.resolvingSymlinksInPath().standardizedFileURL,
            isInside(target, root)
        {
            throw EvaluationReportError.insideRepository
        }
        return target
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        return components.count >= rootComponents.count
            && Array(components.prefix(rootComponents.count)) == rootComponents
    }
}

/// Where an evaluation prints its result.
public enum EvaluationOutput: Equatable {
    case reportFile(String)
    /// To an interactive terminal, with a privacy warning.
    case terminal
    case refusedNonInteractive

    /// Without `--report`, the sample goes to stdout only when that is a terminal, so a pipe or
    /// redirect never captures private clipboard text by accident.
    public static func decide(isTerminal: Bool, reportPath: String?) -> EvaluationOutput {
        if let reportPath { return .reportFile(reportPath) }
        return isTerminal ? .terminal : .refusedNonInteractive
    }
}
