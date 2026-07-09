import AppKit
import SwiftUI

/// A minimal git panel pinned to the bottom of the sidebar. Shows the branch,
/// dirty files, and commit/push/pull actions for the selected tab's repo.
struct GitPanelView: View {
    @ObservedObject var model: GitPanelModel
    var theme: SidebarTheme

    @AppStorage("SidebarGitPanelCollapsed") private var collapsed = false
    @State private var commitMessage = ""

    private static let maxVisibleFiles = 10

    var body: some View {
        if model.repoRoot != nil {
            VStack(alignment: .leading, spacing: 0) {
                Divider()

                header
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                if !collapsed {
                    VStack(alignment: .leading, spacing: 6) {
                        syncRow
                        fileList
                        commitBox
                        if let error = model.errorMessage {
                            errorRow(error)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            .background(theme.background)
        }
    }

    // MARK: - Header (branch + collapse)

    private var header: some View {
        HStack(spacing: 6) {
            branchMenu

            if model.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }

            // The whole rest of the header row is the collapse toggle,
            // so the click target is generous.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)

                    if collapsed && !model.changes.isEmpty {
                        Text("\(model.changes.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.background)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.secondaryText))
                    }

                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private static let maxInlineBranches = 10

    private var branchMenu: some View {
        Menu {
            Button("New Branch…") { promptNewBranch() }
            Button("Pull") { model.pull() }
                .disabled(!model.hasUpstream)
            Button("Push") { model.push() }

            Divider()

            // Branches are sorted by most recent commit; show the first
            // few inline and tuck the long tail into a submenu.
            ForEach(model.branches.prefix(Self.maxInlineBranches), id: \.self) { name in
                branchMenuItem(name)
            }
            if model.branches.count > Self.maxInlineBranches {
                Menu("All Branches") {
                    ForEach(model.branches.dropFirst(Self.maxInlineBranches), id: \.self) { name in
                        branchMenuItem(name)
                    }
                }
            }
        } label: {
            branchMenuLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func branchMenuItem(_ name: String) -> some View {
        let isCurrent = name == model.branch
        Button {
            model.checkout(name)
        } label: {
            if isCurrent {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
        .disabled(isCurrent)
    }

    private var branchMenuLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
            Text(model.isDetached ? "detached" : (model.branch ?? "…"))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(theme.foreground)
    }

    // MARK: - Sync (ahead/behind, pull/push)

    /// Pull/Push appear only when there is actually something to sync.
    /// Both actions are always reachable via the branch menu.
    @ViewBuilder
    private var syncRow: some View {
        if model.hasUpstream && (model.behind > 0 || model.ahead > 0) {
            HStack(spacing: 6) {
                if model.behind > 0 {
                    smallButton("↓ \(model.behind)  Pull", disabled: model.isBusy) {
                        model.pull()
                    }
                }
                if model.ahead > 0 {
                    smallButton("↑ \(model.ahead)  Push", disabled: model.isBusy) {
                        model.push()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func smallButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.activeTabBackground))
                .foregroundColor(disabled ? theme.secondaryText : theme.foreground)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Files

    @ViewBuilder
    private var fileList: some View {
        if model.changes.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9))
                Text("No changes")
                    .font(.system(size: 10))
            }
            .foregroundColor(theme.secondaryText)
            .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.changes.prefix(Self.maxVisibleFiles)) { change in
                    HStack(spacing: 5) {
                        Text(String(change.status))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(statusColor(change.status))
                            .frame(width: 10)
                        Text(change.fileName)
                            .font(.system(size: 10))
                            .foregroundColor(theme.foreground.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(change.path)
                        Spacer(minLength: 0)
                    }
                }
                if model.changes.count > Self.maxVisibleFiles {
                    Text("+ \(model.changes.count - Self.maxVisibleFiles) more")
                        .font(.system(size: 9))
                        .foregroundColor(theme.secondaryText)
                        .padding(.leading, 15)
                }
            }
        }
    }

    private func statusColor(_ status: Character) -> Color {
        switch status {
        case "A", "?": return .green
        case "D": return .red
        case "U": return .purple
        default: return .orange  // M, R, C
        }
    }

    // MARK: - Commit

    @ViewBuilder
    private var commitBox: some View {
        if !model.changes.isEmpty {
            HStack(spacing: 5) {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(theme.foreground)
                    .onSubmit(commit)

                Button(action: commit) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(canCommit ? theme.foreground : theme.secondaryText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .help("Commit all changes")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.foreground.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.secondaryText.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var canCommit: Bool {
        !model.isBusy && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        guard canCommit else { return }
        model.commitAll(message: commitMessage)
        commitMessage = ""
    }

    // MARK: - Error

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(message)
                .font(.system(size: 9))
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.orange)
    }

    // MARK: - New branch prompt

    private func promptNewBranch() {
        let alert = NSAlert()
        alert.messageText = "New Branch"
        alert.informativeText = "Create a new branch from the current HEAD."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.placeholderString = "branch-name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                model.createBranch(name)
            }
        }
    }
}
