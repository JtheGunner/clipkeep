import AppKit
import Testing

@testable import ClipkeepCore

@MainActor
@Suite struct OwnCopyWriterTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("li.wuermli.clipkeep.test.\(UUID().uuidString)"))
    }

    @Test func aSecretCopyCarriesTheMarkersForClipboardManagers() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        #expect(OwnCopyWriter(pasteboard: pasteboard).copySecret("hunter2", clearAfter: 3_600))

        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        #expect(pasteboard.string(forType: .string) == "hunter2")
        #expect(types.contains(OwnCopyWriter.markerType))
        #expect(types.contains("org.nspasteboard.ConcealedType"))
        #expect(types.contains("org.nspasteboard.TransientType"))
    }

    @Test func aSecretCopyIsRemovedAfterTheTimeout() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        OwnCopyWriter(pasteboard: pasteboard).copySecret("hunter2", clearAfter: 0.05)
        try await Task.sleep(for: .milliseconds(400))

        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func anotherCopyInTheMeantimeIsLeftAlone() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let writer = OwnCopyWriter(pasteboard: pasteboard)

        writer.copySecret("hunter2", clearAfter: 0.2)
        writer.copy("something else")
        try await Task.sleep(for: .milliseconds(500))

        #expect(pasteboard.string(forType: .string) == "something else")
    }
}
