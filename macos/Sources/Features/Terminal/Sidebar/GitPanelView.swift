import AppKit
import SwiftUI

/// A minimal git panel pinned to the bottom of the sidebar. Shows the branch,
/// dirty files, and commit/push/pull actions for the selected tab's repo.
struct GitPanelView: View {
    @ObservedObject var model: GitPanelModel
    var theme: SidebarTheme

    @AppStorage("SidebarGitPanelCollapsed") private var collapsed = false
    @State private var commitMessage = ""
    @State private var hoverBranch = false
    @State private var hoverCollapse = false
    @State private var branchAnchor: NSView?
    @State private var menuPresenter = BranchMenuPresenter()

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
        HStack(spacing: 4) {
            // The branch menu owns most of the row; collapse is a compact
            // rectangular button on the right.
            branchMenu

            if model.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }

            if collapsed && !model.changes.isEmpty {
                Text("\(model.changes.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.background)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.secondaryText))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 24, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hoverCollapse ? theme.foreground.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverCollapse = $0 }
        }
    }

    /// A plain full-width button that pops a native NSMenu. SwiftUI's Menu
    /// neither stretches to fill the row nor reports hover reliably.
    private var branchMenu: some View {
        Button {
            guard let anchor = branchAnchor else { return }
            menuPresenter.model = model
            menuPresenter.onNewBranch = { promptNewBranch() }
            menuPresenter.show(relativeTo: anchor)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text(model.isDetached ? "detached" : (model.branch ?? "…"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.foreground)
            .padding(.horizontal, 4)
            .frame(height: 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hoverBranch ? theme.foreground.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .background(NSViewGrabber { branchAnchor = $0 })
        .onHover { hoverBranch = $0 }
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

// MARK: - BranchMenuPresenter

/// Builds and presents the native branch menu for the git panel.
@MainActor
final class BranchMenuPresenter: NSObject {
    var model: GitPanelModel?
    var onNewBranch: (() -> Void)?

    private static let maxInlineBranches = 10

    func show(relativeTo view: NSView) {
        guard let model else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let newBranch = NSMenuItem(title: "New Branch…", action: #selector(newBranchAction), keyEquivalent: "")
        newBranch.target = self
        menu.addItem(newBranch)

        let pull = NSMenuItem(title: "Pull", action: #selector(pullAction), keyEquivalent: "")
        pull.target = self
        pull.isEnabled = model.hasUpstream
        menu.addItem(pull)

        let push = NSMenuItem(title: "Push", action: #selector(pushAction), keyEquivalent: "")
        push.target = self
        menu.addItem(push)

        menu.addItem(.separator())

        // Branches are sorted by most recent commit; show the first few
        // inline and tuck the long tail into a submenu.
        let inline = model.branches.prefix(Self.maxInlineBranches)
        let overflow = model.branches.dropFirst(Self.maxInlineBranches)

        for name in inline {
            menu.addItem(branchItem(name, current: model.branch))
        }
        if !overflow.isEmpty {
            let more = NSMenuItem(title: "All Branches", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for name in overflow {
                submenu.addItem(branchItem(name, current: model.branch))
            }
            more.submenu = submenu
            menu.addItem(more)
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: view.bounds.maxY + 4),
            in: view
        )
    }

    private func branchItem(_ name: String, current: String?) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: #selector(checkoutAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = name
        if name == current {
            item.state = .on
            item.isEnabled = false
        }
        return item
    }

    @objc private func checkoutAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        model?.checkout(name)
    }

    @objc private func pullAction() { model?.pull() }
    @objc private func pushAction() { model?.push() }
    @objc private func newBranchAction() { onNewBranch?() }
}

// MARK: - NSViewGrabber

/// Invisible helper that hands its backing NSView to SwiftUI, used as a
/// positioning anchor for native menus.
private struct NSViewGrabber: NSViewRepresentable {
    let onGrab: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onGrab(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
