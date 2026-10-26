import AppKit
import ClipkeepCore
@preconcurrency import UserNotifications
import os

/// Tells the user that a copy was taken for a secret and offers "Kein Secret" for a short time.
final class SecretNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// How long the undo button stays on screen.
    static let undoWindow: TimeInterval = 60

    private nonisolated static let logger = Logger(
        subsystem: AppInfo.bundleIdentifier, category: "notifications")
    private static let categoryID = "secretParked"
    private static let actionID = "notSecret"

    private let lock = NSLock()
    private var undoHandler: (@Sendable (Int64) async -> Bool)?

    /// Called with the secret's id when the user presses "Kein Secret"; true if it worked.
    func setUndoHandler(_ handler: @escaping @Sendable (Int64) async -> Bool) {
        lock.withLock { undoHandler = handler }
    }

    /// Notifications need an app bundle; a bare executable (swift run) has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        let undo = UNNotificationAction(
            identifier: Self.actionID, title: "Kein Secret", options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID, actions: [undo], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert]) { _, error in
            if let error {
                Self.logger.error(
                    "Notification permission failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    func secretParked(_ secret: ParkedSecret) {
        let content = UNMutableNotificationContent()
        content.title = "Secret gesichert"
        content.body = secret.label
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["id": Int(secret.id)]
        post(content, identifier: "secret-\(secret.id)", expiresAfter: Self.undoWindow)
    }

    private func post(
        _ content: UNMutableNotificationContent, identifier: String, expiresAfter: TimeInterval
    ) {
        guard let center else { return }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) {
            error in
            if let error {
                Self.logger.error(
                    "Notification failed: \(String(describing: error), privacy: .public)")
            }
        }
        // The undo button must not outlive its window.
        DispatchQueue.global().asyncAfter(deadline: .now() + expiresAfter) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [identifier])
        }
    }

    private func report(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Clipkeep"
        content.body = message
        post(content, identifier: "secret-result-\(UUID().uuidString)", expiresAfter: 10)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.actionID,
            let number = response.notification.request.content.userInfo["id"] as? Int
        else { return }
        let id = Int64(number)
        // Pressed after the window (a notification kept in the Notification Center): too late.
        guard Date().timeIntervalSince(response.notification.date) <= Self.undoWindow else {
            report("Rückgängig nicht mehr möglich")
            return
        }
        let handler = lock.withLock { undoHandler }
        let worked = await handler?(id) ?? false
        report(
            worked
                ? "Als normaler Eintrag wiederhergestellt"
                : "Wiederherstellen fehlgeschlagen")
    }
}
