import Foundation
import Cocoa

/// Tracks notifications per tab with unread state.
/// Fed by: IPC `tab.notify` command, bell notifications, desktop notifications (OSC 9/99).
@MainActor
final class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    struct TabNotification: Identifiable, Equatable {
        let id: UUID
        let tabId: UUID       // surface UUID of the tab
        let title: String
        let body: String
        let createdAt: Date
        var isRead: Bool
    }

    @Published private(set) var notifications: [TabNotification] = []

    /// Track which tabs have unread notifications
    @Published private(set) var unreadTabs: Set<UUID> = []

    private init() {}

    func addNotification(tabId: UUID, title: String, body: String = "") {
        let notification = TabNotification(
            id: UUID(),
            tabId: tabId,
            title: title,
            body: body,
            createdAt: Date(),
            isRead: false
        )
        notifications.append(notification)
        unreadTabs.insert(tabId)
    }

    func hasUnread(tabId: UUID) -> Bool {
        unreadTabs.contains(tabId)
    }

    func markRead(tabId: UUID) {
        unreadTabs.remove(tabId)
        for i in notifications.indices where notifications[i].tabId == tabId {
            notifications[i].isRead = true
        }
    }

    func clearAll(tabId: UUID) {
        notifications.removeAll { $0.tabId == tabId }
        unreadTabs.remove(tabId)
    }
}
