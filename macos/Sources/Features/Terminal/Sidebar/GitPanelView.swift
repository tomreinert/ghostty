import AppKit
import SwiftUI

/// A minimal git panel pinned to the bottom of the sidebar. Shows the branch,
/// dirty files, and commit/push/pull actions for the selected tab's repo.
struct GitPanelView: View {
    @ObservedObject var model: GitPanelModel
    var theme: SidebarTheme

    @AppStorage("SidebarGitPanelCollapsed") private var collapsed = false
    @State private var commitMessage = ""
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .background(NSViewGrabber { branchAnchor = $0 })
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
                    FileRow(
                        change: change,
                        theme: theme,
                        statusColor: statusColor(change.status),
                        onOpen: { open(change) }
                    )
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

    /// The user's editor, resolved from $VISUAL/$EDITOR.
    private struct ResolvedEditor {
        /// Full editor command, e.g. "cursor --wait -r" (empty if none set).
        var command: String
        /// The .app bundle the editor's CLI lives in, e.g. "/Applications/Cursor.app"
        /// (empty for terminal editors like vim, or if it couldn't be resolved).
        var appPath: String
    }

    /// Open a changed file in the user's editor ($VISUAL/$EDITOR). For a GUI
    /// editor we hand the file to its running .app so it reuses the open window;
    /// terminal editors are launched via the shell; otherwise the OS default.
    private func open(_ change: GitPanelModel.FileChange) {
        guard let root = model.repoRoot else { return }
        let fullPath = (root as NSString).appendingPathComponent(change.path)
        Task.detached {
            let editor = Self.resolveEditorEnv()
            if !editor.appPath.isEmpty {
                // GUI editor: route the file through its .app bundle. The cursor/
                // code CLI can only target the running window when launched from a
                // terminal *inside* the editor (via VSCODE_IPC_HOOK_CLI), so from
                // Ghostty it would spawn a new window. Handing the file to the app
                // reuses the running instance, like `open -a`.
                await MainActor.run {
                    Self.openWithApp(URL(filePath: fullPath), appPath: editor.appPath)
                }
            } else if !editor.command.isEmpty {
                Self.launchInEditor(editor: editor.command, path: fullPath)
            } else {
                // No $EDITOR/$VISUAL set: fall back to the OS default app,
                // matching how a file link clicked in the terminal opens.
                await MainActor.run { Self.openWithDefaultApp(fullPath) }
            }
        }
    }

    /// Resolve $VISUAL/$EDITOR and, if it's a GUI editor, the .app bundle its CLI
    /// lives in. Ghostty is a GUI app and doesn't inherit the shell profile's
    /// environment, so we source it through a login+interactive shell (which also
    /// puts the editor's CLI on PATH). Values are wrapped in \1 markers so noisy
    /// shell profiles (banners, etc.) can't corrupt what we read back.
    private static func resolveEditorEnv() -> ResolvedEditor {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Resolve the editor, then follow its CLI symlink to the containing .app.
        // perl provides a portable realpath (BSD readlink lacks -f).
        process.arguments = ["-ilc", #"ed="${VISUAL:-$EDITOR}"; cmd="${ed%% *}"; bin="$(command -v "$cmd" 2>/dev/null)"; app=""; if [ -n "$bin" ]; then rp="$(/usr/bin/perl -MCwd -e 'print Cwd::abs_path($ARGV[0])' "$bin" 2>/dev/null)"; case "$rp" in *.app/*) app="${rp%%.app/*}.app";; esac; fi; printf '\1%s\1%s\1' "$ed" "$app""#]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ResolvedEditor(command: "", appPath: "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else {
            return ResolvedEditor(command: "", appPath: "")
        }
        // Layout between markers: <noise>\1<editor>\1<app>\1<noise>
        let parts = text.components(separatedBy: "\u{01}")
        guard parts.count >= 3 else { return ResolvedEditor(command: "", appPath: "") }
        return ResolvedEditor(
            command: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
            appPath: parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Open the file in a specific running/known application bundle, reusing the
    /// running instance (the AppKit equivalent of `open -a`).
    private static func openWithApp(_ fileURL: URL, appPath: String) {
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: URL(fileURLWithPath: appPath),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Launch the file in the resolved editor via a login+interactive shell, so
    /// the editor's CLI is on PATH. Used for editors not backed by a .app. The
    /// editor string is split into words here and passed as separate args: zsh
    /// does not word-split unquoted parameter expansions, so `exec $EDITOR`
    /// would treat "cursor --wait" as one command. `exec "$@"` avoids that.
    private static func launchInEditor(editor: String, path: String) {
        let words = editor.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", #"exec "$@""#, "ghostty"] + words + [path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Open with the OS default application for the file's type, matching how a
    /// file link clicked in the terminal opens (see Ghostty.App.openURL).
    private static func openWithDefaultApp(_ path: String) {
        let url = URL(filePath: path)
        let editor = NSWorkspace.shared.defaultApplicationURL(forExtension: url.pathExtension)
            ?? NSWorkspace.shared.defaultTextEditor
        if let editor {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: editor,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
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

// MARK: - FileRow

/// A single changed-file row. Clicking opens the file in the default editor,
/// matching how a file link clicked in the terminal opens. Deleted files no
/// longer exist on disk, so they aren't clickable.
private struct FileRow: View {
    let change: GitPanelModel.FileChange
    let theme: SidebarTheme
    let statusColor: Color
    let onOpen: () -> Void

    @State private var hover = false

    private var openable: Bool { change.status != "D" }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Text(String(change.status))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(statusColor)
                    .frame(width: 10)
                Text(change.fileName)
                    .font(.system(size: 10))
                    .foregroundColor(theme.foreground.opacity(hover && openable ? 1.0 : 0.85))
                    .underline(hover && openable)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!openable)
        .help(openable ? "Open \(change.path)" : change.path)
        .onHover { hovering in
            hover = hovering
            guard openable else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            // Balance the cursor stack if we vanish while hovered.
            if hover && openable { NSCursor.pop() }
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
