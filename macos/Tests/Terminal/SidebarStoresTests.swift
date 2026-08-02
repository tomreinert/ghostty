import Testing
import Foundation
@testable import Ghostty

/// Tests for the sidebar IPC stores. Both stores are singletons, so every
/// test uses fresh tab UUIDs to stay isolated from the others.
@MainActor
struct TabMetadataStoreTests {
    @Test func setStatusCreatesEntry() {
        let store = TabMetadataStore.shared
        let tab = UUID()
        defer { store.removeAll(for: tab) }

        store.setStatus(tabId: tab, key: "git", value: "main", icon: "arrow.branch")

        let entries = store.statusEntries(for: tab)
        #expect(entries == [.init(key: "git", value: "main", icon: "arrow.branch")])
    }

    @Test func setStatusOverwritesSameKey() {
        let store = TabMetadataStore.shared
        let tab = UUID()
        defer { store.removeAll(for: tab) }

        store.setStatus(tabId: tab, key: "git", value: "main")
        store.setStatus(tabId: tab, key: "git", value: "feature")

        #expect(store.statusEntries(for: tab).map(\.value) == ["feature"])
    }

    @Test func statusEntriesAreSortedByKey() {
        let store = TabMetadataStore.shared
        let tab = UUID()
        defer { store.removeAll(for: tab) }

        store.setStatus(tabId: tab, key: "zeta", value: "2")
        store.setStatus(tabId: tab, key: "alpha", value: "1")

        #expect(store.statusEntries(for: tab).map(\.key) == ["alpha", "zeta"])
    }

    @Test func clearStatusRemovesKeyAndEmptyTab() {
        let store = TabMetadataStore.shared
        let tab = UUID()

        store.setStatus(tabId: tab, key: "git", value: "main")
        store.clearStatus(tabId: tab, key: "git")

        #expect(store.statusEntries(for: tab).isEmpty)
        #expect(store.entries[tab] == nil)
    }

    @Test func clearStatusOnUnknownTabIsANoop() {
        let store = TabMetadataStore.shared
        store.clearStatus(tabId: UUID(), key: "git")
    }

    @Test func removeAllOnlyAffectsTheGivenTab() {
        let store = TabMetadataStore.shared
        let tab1 = UUID()
        let tab2 = UUID()
        defer { store.removeAll(for: tab2) }

        store.setStatus(tabId: tab1, key: "git", value: "main")
        store.setStatus(tabId: tab2, key: "git", value: "dev")
        store.removeAll(for: tab1)

        #expect(store.statusEntries(for: tab1).isEmpty)
        #expect(store.statusEntries(for: tab2).map(\.value) == ["dev"])
    }
}

@MainActor
struct NotificationStoreTests {
    @Test func addNotificationMarksTabUnread() {
        let store = NotificationStore.shared
        let tab = UUID()
        defer { store.clearAll(tabId: tab) }

        store.addNotification(tabId: tab, title: "Build", body: "done")

        #expect(store.hasUnread(tabId: tab))
        let notifs = store.notifications.filter { $0.tabId == tab }
        #expect(notifs.count == 1)
        #expect(notifs.first?.title == "Build")
        #expect(notifs.first?.body == "done")
        #expect(notifs.first?.isRead == false)
    }

    @Test func markReadClearsUnreadAndFlagsNotifications() {
        let store = NotificationStore.shared
        let tab = UUID()
        defer { store.clearAll(tabId: tab) }

        store.addNotification(tabId: tab, title: "one")
        store.addNotification(tabId: tab, title: "two")
        store.markRead(tabId: tab)

        #expect(!store.hasUnread(tabId: tab))
        #expect(store.notifications.filter { $0.tabId == tab }.allSatisfy { $0.isRead })
    }

    @Test func markReadOnlyAffectsTheGivenTab() {
        let store = NotificationStore.shared
        let tab1 = UUID()
        let tab2 = UUID()
        defer {
            store.clearAll(tabId: tab1)
            store.clearAll(tabId: tab2)
        }

        store.addNotification(tabId: tab1, title: "a")
        store.addNotification(tabId: tab2, title: "b")
        store.markRead(tabId: tab1)

        #expect(!store.hasUnread(tabId: tab1))
        #expect(store.hasUnread(tabId: tab2))
    }

    @Test func clearAllRemovesNotificationsAndUnreadState() {
        let store = NotificationStore.shared
        let tab = UUID()

        store.addNotification(tabId: tab, title: "gone")
        store.clearAll(tabId: tab)

        #expect(!store.hasUnread(tabId: tab))
        #expect(store.notifications.filter { $0.tabId == tab }.isEmpty)
    }
}
