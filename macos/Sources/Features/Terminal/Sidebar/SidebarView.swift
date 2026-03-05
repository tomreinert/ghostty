import SwiftUI

/// A vertical sidebar that displays the list of tabs for the current window group.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(tabManager.tabs) { tab in
                    SidebarTabCard(tab: tab)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            tabManager.selectTab(tab)
                        }
                        .contextMenu {
                            Button("Rename Tab...") {
                                tabManager.promptRenameTab(tab)
                            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SidebarTabCard: View {
    let tab: SidebarTabManager.TabItem

    private var branch: String? { tab.metadata["branch"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title row
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundColor(tab.isSelected ? .accentColor : .secondary)

                Text(tab.title)
                    .font(.system(size: 12, weight: tab.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(tab.isSelected ? .primary : .secondary)

                Spacer()
            }

            // Info row: directory and/or git branch
            if tab.directoryName != nil || branch != nil {
                HStack(spacing: 10) {
                    if let dir = tab.directoryName {
                        Text(dir)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if let branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }

            // Custom metadata (anything other than "branch")
            let extraMeta = tab.metadata.filter { $0.key != "branch" }
            if !extraMeta.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(extraMeta.keys.sorted()), id: \.self) { key in
                        if let value = extraMeta[key] {
                            Text("\(key): \(value)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tab.isSelected
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear)
        )
    }
}
