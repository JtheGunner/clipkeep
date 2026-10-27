import ClipkeepCore
import Foundation
import os

/// Runs `MaintenanceService` a little after launch and then every hour, one pass at a time and
/// at low priority, so capture never waits for it.
enum MaintenanceScheduler {
    private static let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "maintenance")
    private static let firstDelay = Duration.seconds(60)
    private static let interval = Duration.seconds(3_600)

    @MainActor private static var task: Task<Void, Never>?

    /// Starts the loop once; a second call is ignored.
    @MainActor static func start(database: Database) {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) {
            let service = MaintenanceService(database: database)
            do { try await Task.sleep(for: firstDelay) } catch { return }
            while !Task.isCancelled {
                let report = service.run()
                if report.failures.isEmpty {
                    logger.info(
                        "Maintenance done: sessionsRebuilt=\(report.sessionsRebuilt, privacy: .public) topics=\(report.topicsPlaced, privacy: .public) tiers=\(report.tierChanges, privacy: .public) purged=\(report.purged, privacy: .public) indexed=\(report.indexed, privacy: .public)"
                    )
                } else {
                    logger.error(
                        "Maintenance steps failed: \(report.failures.joined(separator: ","), privacy: .public)"
                    )
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    @MainActor static func stop() {
        task?.cancel()
        task = nil
    }
}
