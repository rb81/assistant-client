import AppKit
import UserNotifications

/// Isolates system notification delivery so inactive-app behavior can be verified without posting real alerts.
@MainActor protocol ClientNotificationDelivering {
    var applicationIsActive: Bool { get }
    func deliver(_ request: UNNotificationRequest) async throws
}

/// Native alerts are delivered by macOS, never by a second app window.
struct SystemNotificationDelivery: ClientNotificationDelivering {
    var applicationIsActive: Bool { NSApp.isActive }

    func deliver(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}
