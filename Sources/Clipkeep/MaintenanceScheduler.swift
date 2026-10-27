import ClipkeepCore
import Foundation
import os

/// Runs `MaintenanceService` a little after launch and then every hour, one pass at a time and
/// at low priority, so capture never waits for it.
enum MaintenanceScheduler {
    private static let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "maintenance")
    private static let firstDelay = Duration.seconds(60)
    private static let interval = Duration.seconds(3_600)

    static func start(database: Database) {
        Task.detached(priority: .background) {
            let service = MaintenanceService(database: database)
            try? await Task.sleep(for: firstDelay)
            while !Task.isCancelled {
                let report = service.run()
                if report.failures.isEmpty {
                    logger.info(
                        "Maintenance done: \(report.topicsPlaced, privacy: .public) sessions placed, \(report.purged, privacy: .public) purged"
                    )
                } else {
                    logger.error(
                        "Maintenance steps failed: \(report.failures.joined(separator: ","), privacy: .public)"
                    )
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
