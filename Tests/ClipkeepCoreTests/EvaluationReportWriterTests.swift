import Foundation
import Testing

@testable import ClipkeepCore

@Suite struct EvaluationReportWriterTests {
    private struct Sandbox {
        let base: URL
        let repository: URL
        let outside: URL

        init() throws {
            let manager = FileManager.default
            base = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: manager.temporaryDirectory, create: true)
            repository = base.appendingPathComponent("repo")
            outside = base.appendingPathComponent("outside")
            try manager.createDirectory(
                at: repository.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try manager.createDirectory(at: outside, withIntermediateDirectories: true)
            manager.createFile(
                atPath: repository.appendingPathComponent("Package.swift").path, contents: nil)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    @Test func createsAnOwnerOnlyFileOutsideTheRepository() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let path = sandbox.outside.appendingPathComponent("report.txt").path

        try EvaluationReportWriter.write("content", to: path, repositoryRoot: sandbox.repository)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "content")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)
    }

    @Test func refusesAPathInsideTheRepository() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let path = sandbox.repository.appendingPathComponent("sub/report.txt").path

        #expect(throws: EvaluationReportError.insideRepository) {
            try EvaluationReportWriter.write("x", to: path, repositoryRoot: sandbox.repository)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func refusesARelativePathFromASubdirectoryOfTheRepository() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let subdirectory = sandbox.repository.appendingPathComponent("sub")
        let root = EvaluationReportWriter.repositoryRoot(startingAt: subdirectory)

        #expect(throws: EvaluationReportError.insideRepository) {
            try EvaluationReportWriter.write(
                "x", to: "report.txt", repositoryRoot: root, workingDirectory: subdirectory)
        }
        #expect(throws: EvaluationReportError.insideRepository) {
            try EvaluationReportWriter.write(
                "x", to: "../report.txt", repositoryRoot: root, workingDirectory: subdirectory)
        }
    }

    @Test func refusesAPathThatReachesTheRepositoryThroughASymlink() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let link = sandbox.outside.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: sandbox.repository.appendingPathComponent("sub"))

        #expect(throws: EvaluationReportError.insideRepository) {
            try EvaluationReportWriter.write(
                "x", to: link.appendingPathComponent("report.txt").path,
                repositoryRoot: sandbox.repository)
        }
    }

    @Test func refusesAnExistingFileAndALeavesItUntouched() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let path = sandbox.outside.appendingPathComponent("report.txt").path
        try "old".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(throws: EvaluationReportError.alreadyExists) {
            try EvaluationReportWriter.write("new", to: path, repositoryRoot: sandbox.repository)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "old")
    }

    @Test func refusesASymlinkAtThePath() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let victim = sandbox.outside.appendingPathComponent("victim.txt")
        let link = sandbox.outside.appendingPathComponent("report.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        #expect(throws: EvaluationReportError.self) {
            try EvaluationReportWriter.write(
                "x", to: link.path, repositoryRoot: sandbox.repository)
        }
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func refusesAMissingParentDirectory() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let path = sandbox.outside.appendingPathComponent("missing/report.txt").path

        #expect(throws: EvaluationReportError.parentMissing) {
            try EvaluationReportWriter.write("x", to: path, repositoryRoot: sandbox.repository)
        }
    }

    @Test func printsToStdoutOnlyOnATerminalWithoutAReport() {
        #expect(EvaluationOutput.decide(isTerminal: true, reportPath: nil) == .terminal)
        #expect(
            EvaluationOutput.decide(isTerminal: false, reportPath: nil) == .refusedNonInteractive)
        #expect(
            EvaluationOutput.decide(isTerminal: false, reportPath: "r.txt") == .reportFile("r.txt"))
        #expect(
            EvaluationOutput.decide(isTerminal: true, reportPath: "r.txt") == .reportFile("r.txt"))
    }
}
