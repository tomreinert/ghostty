import Cocoa
import Combine

/// Observes the tab group of a window and publishes tab metadata for the sidebar.
@MainActor
class SidebarTabManager: ObservableObject {
    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let pwd: String?
        let gitBranch: String?
        let surfaceId: UUID?
        let statusEntries: [TabMetadataStore.StatusEntry]
        let isSelected: Bool
        let needsAttention: Bool
        let tabColor: TerminalTabColor
        let window: NSWindow

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return (pwd as NSString).lastPathComponent
        }

        /// Title with bell emoji stripped (the sidebar uses its own attention indicator).
        var displayTitle: String {
            title.hasPrefix("\u{1F514} ") ? String(title.dropFirst(3)) : title
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.isSelected == rhs.isSelected
                && lhs.pwd == rhs.pwd && lhs.gitBranch == rhs.gitBranch
                && lhs.surfaceId == rhs.surfaceId
                && lhs.statusEntries == rhs.statusEntries
                && lhs.needsAttention == rhs.needsAttention
                && lhs.tabColor == rhs.tabColor
        }
    }

    @Published var tabs: [TabItem] = []

    /// True between a drop and the deferred window reorder; `refresh()`
    /// skips while set so the still-old window order can't snap the list
    /// back for a frame.
    private var isCommittingDrag = false

    /// Windows that need attention, cleared when the tab is selected.
    private var attentionWindows: Set<ObjectIdentifier> = []

    /// Whether bells should trigger the sidebar attention indicator.
    /// Derived from `bell-features` containing `attention`.
    private let bellTriggersAttention: Bool

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(window: NSWindow, bellTriggersAttention: Bool = true) {
        self.window = window
        self.bellTriggersAttention = bellTriggersAttention
        setupObservers()
        refresh()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        let titleObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        observers.append(titleObserver)

        let resignObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        observers.append(resignObserver)

        // Bell: respect bell-features config
        if bellTriggersAttention {
            let bellObserver = center.addObserver(
                forName: .terminalWindowBellDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let controller = notification.object as? BaseTerminalController,
                      let w = controller.window else { return }
                let hasBell = notification.userInfo?[Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
                if hasBell {
                    self.markAttention(window: w)
                } else {
                    self.clearAttention(for: ObjectIdentifier(w))
                    self.refresh()
                }
            }
            observers.append(bellObserver)
        }

        // Desktop notifications (OSC 9/99, command completion): always trigger attention
        let desktopNotifObserver = center.addObserver(
            forName: .ghosttyDesktopNotificationDidFire,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceView = notification.object as? Ghostty.SurfaceView,
                  let w = surfaceView.window else { return }
            self.markAttention(window: w)
        }
        observers.append(desktopNotifObserver)

        // IPC notifications (tab.notify command): trigger attention
        let ipcNotifObserver = center.addObserver(
            forName: .ghosttyIPCNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let w = notification.object as? NSWindow else { return }
            self.markAttention(window: w)
        }
        observers.append(ipcNotifObserver)

        // Poll periodically for tab group changes, title changes, pwd changes, metadata changes.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Attention

    private func markAttention(window w: NSWindow) {
        // Don't mark attention for the currently selected tab — the user can already see it.
        let selected = window?.tabGroup?.selectedWindow ?? window
        guard w !== selected else { return }
        attentionWindows.insert(ObjectIdentifier(w))
        refresh()
    }

    private func clearAttention(for id: ObjectIdentifier) {
        attentionWindows.remove(id)
    }

    // MARK: - Git Branch

    /// Read the git branch from .git/HEAD in the given directory.
    /// Walks up to find the repo root (supports subdirectories).
    private func gitBranch(at pwd: String) -> String? {
        var dir = pwd
        while dir != "/" {
            let headPath = (dir as NSString).appendingPathComponent(".git/HEAD")
            if let contents = try? String(contentsOfFile: headPath, encoding: .utf8) {
                let prefix = "ref: refs/heads/"
                if contents.hasPrefix(prefix) {
                    return contents.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil // detached HEAD
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - Refresh

    func refresh() {
        guard let window, !isCommittingDrag else { return }

        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            tabWindows = [window]
        }

        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let metadataStore = TabMetadataStore.shared

        let newTabs = tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.focusedSurface
            let wid = ObjectIdentifier(w)
            let sid = surface?.id
            let pwd = surface?.pwd
            let entries = sid.map { metadataStore.statusEntries(for: $0) } ?? []
            let branch = pwd.flatMap { gitBranch(at: $0) }
            let color = (w as? TerminalWindow)?.tabColor ?? .none

            return TabItem(
                id: wid,
                title: w.title,
                pwd: pwd,
                gitBranch: branch,
                surfaceId: sid,
                statusEntries: entries,
                isSelected: w === selectedWindow,
                needsAttention: attentionWindows.contains(wid) && w !== selectedWindow,
                tabColor: color,
                window: w
            )
        }

        if newTabs != tabs {
            tabs = newTabs
        }
    }

    // MARK: - Tab Actions

    func selectTab(_ tab: TabItem) {
        clearAttention(for: tab.id)
        tab.window.makeKeyAndOrderFront(nil)
    }

    func setTabColor(_ color: TerminalTabColor, for tab: TabItem) {
        (tab.window as? TerminalWindow)?.tabColor = color
        refresh()
    }

    func closeTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? TerminalController else { return }
        controller.closeTab(nil)
    }

    func renameTab(_ tab: TabItem, to newTitle: String) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.titleOverride = newTitle.isEmpty ? nil : newTitle
        refresh()
    }

    func promptRenameTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.promptTabTitle()
    }

    func closeOtherTabs(_ tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        for w in tabWindows where ObjectIdentifier(w) != tab.id {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    // MARK: - Drag Reordering

    /// Move the dragged tab so it sits before the tab currently at
    /// `insertIndex`, or at the end when `insertIndex == tabs.count`.
    func commitDrag(_ draggedID: ObjectIdentifier, insertAt insertIndex: Int) {
        let index = max(0, min(insertIndex, tabs.count))
        guard let source = tabs.firstIndex(where: { $0.id == draggedID }),
              // The dragged tab's own slot: nothing to do.
              index != source, index != source + 1
        else { return }

        // Snap the list to its final order right away; the window tab
        // group follows a tick later so the UI never waits on the heavy
        // AppKit tab-group work.
        tabs.move(fromOffsets: IndexSet(integer: source), toOffset: index)
        isCommittingDrag = true
        DispatchQueue.main.async { [weak self] in
            self?.reorderWindow(draggedID: draggedID, insertAt: index)
        }
    }

    private func reorderWindow(draggedID: ObjectIdentifier, insertAt insertIndex: Int) {
        isCommittingDrag = false
        defer { refresh() }

        guard let window,
              let tabGroup = window.tabGroup,
              let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty,
              let source = tabbedWindows.firstIndex(where: { ObjectIdentifier($0) == draggedID })
        else { return }

        let index = min(insertIndex, tabbedWindows.count)
        if index == source || index == source + 1 { return }

        let movingWindow = tabbedWindows[source]
        let anchor: NSWindow
        let ordered: NSWindow.OrderingMode
        if index == tabbedWindows.count {
            anchor = tabbedWindows[tabbedWindows.count - 1]
            ordered = .above // after the last tab
        } else {
            anchor = tabbedWindows[index]
            ordered = .below // before the anchor tab
        }
        let selectedWindow = tabGroup.selectedWindow

        // The window must leave the group before re-adding at the anchor;
        // adding a window already in the group appends it at the end.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(movingWindow)
        anchor.addTabbedWindowSafely(movingWindow, ordered: ordered)
        selectedWindow?.makeKeyAndOrderFront(nil)
        NSAnimationContext.endGrouping()
    }

    func closeTabsToTheRight(of tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        guard let idx = tabWindows.firstIndex(where: { ObjectIdentifier($0) == tab.id }) else { return }
        for w in tabWindows[(idx + 1)...] {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }
}
