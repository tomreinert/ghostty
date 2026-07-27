import SwiftUI

// MARK: - SidebarTheme

struct SidebarTheme: Equatable {
    let background: Color
    let foreground: Color
    let secondaryText: Color
    let activeTabBackground: Color
    let attentionColor: Color

    /// Create from Ghostty terminal colors.
    static func from(background: NSColor, foreground: NSColor) -> SidebarTheme {
        let bgLuminance = background.luminance
        let sidebarBg: Color
        if bgLuminance > 0.5 {
            // Light theme: darken sidebar slightly
            sidebarBg = Color(nsColor: background.darken(by: 0.05))
        } else {
            // Dark theme: lighten sidebar slightly
            sidebarBg = Color(nsColor: background.blended(withFraction: 0.08, of: NSColor.white) ?? background)
        }

        let fg = Color(nsColor: foreground)

        return SidebarTheme(
            background: sidebarBg,
            foreground: fg,
            secondaryText: fg.opacity(0.6),
            activeTabBackground: fg.opacity(0.12),
            attentionColor: .orange
        )
    }

    /// Sensible default when no terminal colors are available yet.
    static var `default`: SidebarTheme {
        SidebarTheme(
            background: Color(nsColor: .controlBackgroundColor),
            foreground: .primary,
            secondaryText: .secondary,
            activeTabBackground: Color.accentColor.opacity(0.12),
            attentionColor: .orange
        )
    }
}

// MARK: - SidebarField

enum SidebarField: String, Hashable {
    case title
    case directory
    case gitBranch = "git-branch"
    case status

    static let defaultFields: Set<SidebarField> = [.title, .directory, .gitBranch, .status]
}

// MARK: - SidebarView

/// A vertical sidebar that displays the list of tabs for the current window group.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    var theme: SidebarTheme
    var fields: Set<SidebarField> = SidebarField.defaultFields
    /// Git panel model; nil when the panel is disabled via `sidebar-git`.
    var gitModel: GitPanelModel?

    @AppStorage("SidebarShowCardBorder") private var showCardBorder: Bool = true
    @AppStorage("SidebarDimInactiveColors") private var dimInactiveColors: Bool = false

    /// Card frames keyed by tab ID, in the list coordinate space; a drag
    /// snapshots these as its stable geometry reference.
    @State private var rowFrames: [ObjectIdentifier: CGRect] = [:]
    /// The in-flight drag, or nil. All reorder math runs against the
    /// snapshot taken at drag start, so live layout can't feed back.
    @State private var dragState: TabDragState?

    private static let dropSpaceName = "SidebarTabDrop"
    /// Must match the tab list's VStack spacing.
    private static let rowSpacing: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            tabList

            if let gitModel {
                GitPanelView(model: gitModel, theme: theme)
                    .onReceive(tabManager.$tabs) { tabs in
                        gitModel.pwd = tabs.first(where: { $0.isSelected })?.pwd
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    private var tabList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(tabManager.tabs) { tab in
                    SidebarTabCard(tab: tab, theme: theme, fields: fields, showCardBorder: showCardBorder, dimInactive: dimInactiveColors)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            tabManager.selectTab(tab)
                        }
                        .background(rowFrameReporter(tab.id))
                        .offset(y: offsetY(for: tab.id))
                        .scaleEffect(isLifted(tab.id) ? 1.02 : 1.0)
                        .shadow(
                            color: .black.opacity(isLifted(tab.id) ? 0.25 : 0),
                            radius: 6, y: 2
                        )
                        .zIndex(dragState?.id == tab.id ? 1 : 0)
                        .gesture(dragGesture(for: tab))
                        .contextMenu {
                            Button("Rename Tab...") {
                                tabManager.promptRenameTab(tab)
                            }

                            Divider()

                            Menu("Tab Color") {
                                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                                    Button {
                                        tabManager.setTabColor(color, for: tab)
                                    } label: {
                                        Label {
                                            Text(color.localizedName)
                                        } icon: {
                                            Image(nsImage: color.swatchImage(selected: color == tab.tabColor))
                                        }
                                    }
                                }
                            }

                            Toggle("Show Tab Border", isOn: $showCardBorder)
                            Toggle("Dim Inactive Tab Colors", isOn: $dimInactiveColors)

                            Divider()

                            Button("Close Tab") {
                                tabManager.closeTab(tab)
                            }

                            Button("Close Other Tabs") {
                                tabManager.closeOtherTabs(tab)
                            }
                            .disabled(tabManager.tabs.count <= 1)

                            Button("Close Tabs to the Right") {
                                tabManager.closeTabsToTheRight(of: tab)
                            }
                            .disabled({
                                guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return true }
                                return idx >= tabManager.tabs.count - 1
                            }())
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .coordinateSpace(name: Self.dropSpaceName)
        .onPreferenceChange(SidebarRowFrameKey.self) { rowFrames = $0 }
    }

    private func rowFrameReporter(_ id: ObjectIdentifier) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: SidebarRowFrameKey.self,
                value: [id: geo.frame(in: .named(Self.dropSpaceName))]
            )
        }
    }

    // MARK: Drag to reorder

    /// Whether the card shows the lift (scale + shadow): while actively
    /// dragged, but not during the settle glide — the lift animates down
    /// together with the card sliding into its slot.
    private func isLifted(_ tabID: ObjectIdentifier) -> Bool {
        guard let drag = dragState else { return false }
        return drag.id == tabID && !drag.settling
    }

    /// The dragged card follows the cursor; every other card shifts by one
    /// dragged-card height toward the vacated slot when the drag's target
    /// position passes it.
    private func offsetY(for tabID: ObjectIdentifier) -> CGFloat {
        guard let drag = dragState else { return 0 }
        if drag.id == tabID { return drag.offsetY }
        guard let myIndex = drag.order.firstIndex(of: tabID) else { return 0 }

        let source = drag.sourceIndex
        // This card's position among the non-dragged cards, and where that
        // position ends up once the dragged card occupies the target slot.
        let j = myIndex < source ? myIndex : myIndex - 1
        let finalPos = j < drag.targetSlot ? j : j + 1
        return CGFloat(finalPos - myIndex) * (drag.draggedHeight + Self.rowSpacing)
    }

    private func dragGesture(for tab: SidebarTabManager.TabItem) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if let drag = dragState, drag.id != tab.id || drag.settling { return }
                if dragState == nil {
                    dragState = TabDragState(
                        id: tab.id,
                        order: tabManager.tabs.map(\.id),
                        frames: rowFrames,
                        targetSlot: tabManager.tabs.firstIndex { $0.id == tab.id } ?? 0
                    )
                }
                dragState?.offsetY = value.translation.height
                if let drag = dragState {
                    let slot = targetSlot(for: drag)
                    if slot != drag.targetSlot {
                        withAnimation(.snappy(duration: 0.2)) {
                            dragState?.targetSlot = slot
                        }
                    }
                }
            }
            .onEnded { _ in
                settleDrag()
            }
    }

    /// The dragged card's final position, from its visual center against
    /// the other cards' snapshot midpoints.
    private func targetSlot(for drag: TabDragState) -> Int {
        guard let base = drag.frames[drag.id] else { return drag.sourceIndex }
        let center = base.midY + drag.offsetY
        return drag.order
            .filter { $0 != drag.id }
            .compactMap { drag.frames[$0] }
            .count { $0.midY < center }
    }

    /// Release: glide the card into its slot, then commit the new order —
    /// visually a no-op, since the settled offsets already match it.
    private func settleDrag() {
        guard let drag = dragState, !drag.settling else { return }

        let source = drag.sourceIndex
        let others = drag.order.filter { $0 != drag.id }.compactMap { drag.frames[$0] }
        var settleY: CGFloat = 0
        if let base = drag.frames[drag.id] {
            if drag.targetSlot < source, drag.targetSlot < others.count {
                settleY = others[drag.targetSlot].minY - base.minY
            } else if drag.targetSlot > source, drag.targetSlot - 1 < others.count {
                settleY = others[drag.targetSlot - 1].maxY - base.height - base.minY
            }
        }

        // One glide: the card slides into its slot while the lift (scale
        // and shadow) comes down with it. The commit runs from the
        // animation's own completion, so there's no timer gap between
        // settling and the model update.
        if #available(macOS 14.0, *) {
            withAnimation(.snappy(duration: 0.2)) {
                dragState?.settling = true
                dragState?.offsetY = settleY
            } completion: {
                finishDrag()
            }
        } else {
            // No completion callback pre-14: use a curve that ends exactly
            // at its duration and commit right then.
            withAnimation(.easeOut(duration: 0.2)) {
                dragState?.settling = true
                dragState?.offsetY = settleY
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                finishDrag()
            }
        }
    }

    private func finishDrag() {
        guard let drag = dragState else { return }
        let source = drag.sourceIndex
        let insertIndex = drag.targetSlot < source ? drag.targetSlot : drag.targetSlot + 1
        // Clear the drag and commit in the same update: the new base
        // layout lands exactly where the settled offsets were.
        dragState = nil
        tabManager.commitDrag(drag.id, insertAt: insertIndex)
    }
}

// MARK: - Drag Support

/// An in-flight drag-to-reorder. Order and frames are snapshotted at drag
/// start so the math runs against stable geometry while offsets animate.
private struct TabDragState {
    let id: ObjectIdentifier
    /// Tab IDs in visual order at drag start.
    let order: [ObjectIdentifier]
    /// Card frames at drag start, in the list coordinate space.
    let frames: [ObjectIdentifier: CGRect]
    /// The dragged card's live offset from its base position.
    var offsetY: CGFloat = 0
    /// The position the dragged card would land at right now (0-based
    /// index in the final order).
    var targetSlot: Int
    /// True while the card glides into its slot after release; input is
    /// ignored until the pending commit lands.
    var settling = false

    var sourceIndex: Int { order.firstIndex(of: id) ?? 0 }
    var draggedHeight: CGFloat { frames[id]?.height ?? 0 }
}

/// Card frames keyed by tab ID, collected via preferences in the list's
/// named coordinate space.
private struct SidebarRowFrameKey: PreferenceKey {
    static let defaultValue: [ObjectIdentifier: CGRect] = [:]

    static func reduce(value: inout [ObjectIdentifier: CGRect], nextValue: () -> [ObjectIdentifier: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - SidebarTabCard

private struct SidebarTabCard: View {
    let tab: SidebarTabManager.TabItem
    let theme: SidebarTheme
    let fields: Set<SidebarField>
    var showCardBorder: Bool = true
    var dimInactive: Bool = false

    @State private var hoverDirectory = false

    private static let cardRadius: CGFloat = 8

    /// The accent color for the left border strip.
    /// When dimming is enabled, inactive tabs use reduced opacity for a gentle dim.
    /// When no color is set (.none), the strip is fully transparent.
    private var accentColor: Color {
        if let nsColor = tab.tabColor.displayColor {
            let base = Color(nsColor: nsColor)
            return (dimInactive && !tab.isSelected) ? base.opacity(0.55) : base
        }
        return .clear
    }

    /// The border color for the thin card border — always neutral gray.
    private var cardBorderColor: Color {
        Color(nsColor: .separatorColor).opacity(0.3)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left color accent strip — uses UnevenRoundedRectangle so it
            // follows the card's left-side rounding while staying flat on the right.
            UnevenRoundedRectangle(
                topLeadingRadius: Self.cardRadius,
                bottomLeadingRadius: Self.cardRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(accentColor)
            .frame(width: 5)

            VStack(alignment: .leading, spacing: 4) {
                // Title (always shown — attention dot lives here)
                if fields.contains(.title) {
                    HStack(spacing: 6) {
                        Text(tab.displayTitle)
                            .font(.system(size: 12, weight: tab.isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(tab.isSelected ? theme.foreground : theme.secondaryText)

                        Spacer()

                        if tab.needsAttention {
                            Circle()
                                .fill(theme.attentionColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                }

                // Directory name
                if fields.contains(.directory), let dir = tab.directoryName {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                        Text(dir)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                            .underline(hoverDirectory)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let pwd = tab.pwd else { return }
                        NSWorkspace.shared.open(URL(fileURLWithPath: pwd, isDirectory: true))
                    }
                    .help(tab.pwd.map { "Open \($0) in Finder" } ?? "")
                    .onHover { hovering in
                        hoverDirectory = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .onDisappear {
                        // Balance the cursor stack if we vanish while hovered.
                        if hoverDirectory { NSCursor.pop() }
                    }
                }

                // Git branch
                if fields.contains(.gitBranch), let branch = tab.gitBranch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                        Text(branch)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                // Status entries
                if fields.contains(.status), !tab.statusEntries.isEmpty {
                    ForEach(tab.statusEntries, id: \.key) { entry in
                        HStack(spacing: 4) {
                            if let icon = entry.icon {
                                Image(systemName: icon)
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.secondaryText)
                            }
                            Text(entry.value)
                                .font(.system(size: 10))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 8)
            .padding(.trailing, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius))
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(tab.isSelected ? theme.activeTabBackground : Color.clear)
        )
        .overlay(
            Group {
                if showCardBorder {
                    RoundedRectangle(cornerRadius: Self.cardRadius)
                        .strokeBorder(cardBorderColor, lineWidth: 1)
                }
            }
        )
    }
}
