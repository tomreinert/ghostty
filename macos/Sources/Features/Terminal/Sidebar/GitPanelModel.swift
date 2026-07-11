import Foundation
import Combine
import CoreServices

/// Observes the git repository at the selected tab's working directory and
/// exposes state and actions (checkout, commit, push, pull) for the sidebar
/// git panel. All git access shells out to /usr/bin/git off the main thread.
@MainActor
final class GitPanelModel: ObservableObject {
    struct FileChange: Identifiable, Equatable {
        let path: String
        /// Single porcelain status character: M, A, D, R, C, U or ?
        let status: Character

        var id: String { path }
        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String? {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? nil : dir
        }
    }

    @Published private(set) var repoRoot: String?
    @Published private(set) var branch: String?
    @Published private(set) var isDetached = false
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var hasUpstream = false
    @Published private(set) var changes: [FileChange] = []
    @Published private(set) var branches: [String] = []
    /// True while a user action (checkout/commit/push/pull) is running.
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    /// The working directory of the selected tab. Setting it re-resolves the repo.
    var pwd: String? {
        didSet {
            guard pwd != oldValue else { return }
            Task { await refresh() }
        }
    }

    private var timer: Timer?
    private var isRefreshing = false
    private var needsRefresh = false
    private var watcher: DirectoryWatcher?

    init() {
        // FSEvents on the repo root drives refreshes; this timer is only a
        // fallback for changes FSEvents can't see (e.g. network volumes).
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Refresh

    func refresh() async {
        // Coalesce: a refresh requested mid-refresh runs once more at the end
        // instead of being dropped, so a watcher event can't be lost.
        if isRefreshing {
            needsRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsRefresh = false
            await refreshOnce()
        } while needsRefresh
    }

    private func refreshOnce() async {
        guard let pwd, let root = Self.findRepoRoot(from: pwd) else {
            clearState()
            return
        }

        // --no-optional-locks avoids touching the index so we never contend
        // with git commands the user runs in the terminal.
        async let statusResult = Self.runGit(
            ["--no-optional-locks", "status", "--porcelain", "--branch"],
            in: root
        )
        async let branchesResult = Self.runGit(
            ["for-each-ref", "refs/heads", "--format=%(refname:short)", "--sort=-committerdate"],
            in: root
        )

        let status = await statusResult
        let refs = await branchesResult

        // The repo may have vanished (e.g. directory deleted) between checks.
        guard status.code == 0 else {
            clearState()
            return
        }

        setIfChanged(\.repoRoot, root)
        startWatching(root)
        parseStatus(status.stdout)
        if refs.code == 0 {
            setIfChanged(\.branches, refs.stdout.split(separator: "\n").map(String.init))
        }
    }

    private func clearState() {
        watcher = nil
        setIfChanged(\.repoRoot, nil)
        setIfChanged(\.branch, nil)
        setIfChanged(\.isDetached, false)
        setIfChanged(\.ahead, 0)
        setIfChanged(\.behind, 0)
        setIfChanged(\.hasUpstream, false)
        setIfChanged(\.changes, [])
        setIfChanged(\.branches, [])
    }

    /// Assign a @Published property only when the value actually changed, so
    /// the periodic refresh doesn't re-render the panel when nothing moved.
    private func setIfChanged<T: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<GitPanelModel, T>, _ value: T
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    /// (Re)start the FSEvents watcher when the repo root changes. Events from
    /// the working tree and .git both land here; FSEvents coalesces bursts.
    private func startWatching(_ root: String) {
        guard watcher?.path != root else { return }
        watcher = DirectoryWatcher(path: root) { [weak self] in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    private func parseStatus(_ output: String) {
        var newChanges: [FileChange] = []

        for line in output.split(separator: "\n") {
            if line.hasPrefix("## ") {
                parseBranchLine(String(line.dropFirst(3)))
                continue
            }
            guard line.count > 3 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
            // Renames are "orig -> new"; show the new path.
            if let range = path.range(of: " -> ") {
                path = String(path[range.upperBound...])
            }
            // Quoted paths (special characters): strip the quotes for display.
            if path.hasPrefix("\""), path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
            }

            let status: Character
            if x == "?" {
                status = "?"
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                status = "U"
            } else if y != " " {
                status = y
            } else {
                status = x
            }
            newChanges.append(FileChange(path: path, status: status))
        }

        setIfChanged(\.changes, newChanges)
    }

    private func parseBranchLine(_ line: String) {
        var newBranch: String?
        var newAhead = 0
        var newBehind = 0
        var newHasUpstream = false
        var newIsDetached = false

        if line.hasPrefix("HEAD (no branch)") {
            newIsDetached = true
        } else if line.hasPrefix("No commits yet on ") {
            newBranch = String(line.dropFirst("No commits yet on ".count))
        } else {
            // Format: "name" or "name...upstream" or "name...upstream [ahead 1, behind 2]"
            var head = line
            if let bracket = head.range(of: " [") {
                let counts = head[bracket.upperBound...]
                if let r = counts.range(of: "ahead ") {
                    newAhead = Int(counts[r.upperBound...].prefix(while: \.isNumber)) ?? 0
                }
                if let r = counts.range(of: "behind ") {
                    newBehind = Int(counts[r.upperBound...].prefix(while: \.isNumber)) ?? 0
                }
                head = String(head[..<bracket.lowerBound])
            }
            if let dots = head.range(of: "...") {
                newHasUpstream = true
                head = String(head[..<dots.lowerBound])
            }
            newBranch = head
        }

        setIfChanged(\.branch, newBranch)
        setIfChanged(\.ahead, newAhead)
        setIfChanged(\.behind, newBehind)
        setIfChanged(\.hasUpstream, newHasUpstream)
        setIfChanged(\.isDetached, newIsDetached)
    }

    // MARK: - Actions

    func checkout(_ name: String) {
        performAction { root in
            await Self.runGit(["checkout", name], in: root)
        }
    }

    func createBranch(_ name: String) {
        performAction { root in
            await Self.runGit(["checkout", "-b", name], in: root)
        }
    }

    func commitAll(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performAction { root in
            let add = await Self.runGit(["add", "-A"], in: root)
            guard add.code == 0 else { return add }
            return await Self.runGit(["commit", "-m", trimmed], in: root)
        }
    }

    func pull() {
        performAction { root in
            await Self.runGit(["pull", "--ff-only"], in: root)
        }
    }

    func push() {
        let branch = self.branch
        performAction { root in
            let push = await Self.runGit(["push"], in: root)
            // First push of a new branch: set the upstream automatically.
            if push.code != 0, push.stderr.contains("no upstream"), let branch {
                return await Self.runGit(["push", "--set-upstream", "origin", branch], in: root)
            }
            return push
        }
    }

    /// Runs a git action with busy state and error reporting, then refreshes.
    private func performAction(_ body: @escaping (String) async -> GitResult) {
        guard let repoRoot, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            let result = await body(repoRoot)
            if result.code != 0 {
                errorMessage = Self.summarizeError(result)
            }
            isBusy = false
            await refresh()
        }
    }

    /// Condense git's stderr into a short message for the panel.
    private static func summarizeError(_ result: GitResult) -> String {
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        let lines = text.split(separator: "\n")
        // Prefer the first "fatal:"/"error:" line, else the first line.
        let summary = lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
            ?? lines.first
            ?? "git failed"
        return summary
            .replacingOccurrences(of: "fatal: ", with: "")
            .replacingOccurrences(of: "error: ", with: "")
    }

    // MARK: - Git plumbing

    struct GitResult {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    /// Walk up from a directory to find the repo root (a directory containing
    /// ".git", which may itself be a file for worktrees/submodules).
    nonisolated private static func findRepoRoot(from pwd: String) -> String? {
        var dir = pwd
        let fm = FileManager.default
        while dir != "/" && !dir.isEmpty {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    nonisolated private static func runGit(_ args: [String], in dir: String) async -> GitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
                // Never block on interactive credential prompts.
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = env

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: GitResult(
                        code: -1, stdout: "", stderr: error.localizedDescription
                    ))
                    return
                }

                // Read before waiting so large output can't deadlock the pipe.
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: GitResult(
                    code: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}

// MARK: - DirectoryWatcher

/// Watches a directory tree via FSEvents and invokes a callback when anything
/// under it changes. Watching the repo root covers both the working tree and
/// .git, so edits, commits, and branch switches all trigger the callback.
/// The FSEvents latency parameter coalesces bursts (e.g. a checkout touching
/// hundreds of files) into a single callback.
private final class DirectoryWatcher {
    let path: String
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info)
                    .takeUnretainedValue().onChange()
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // seconds of coalescing before events are delivered
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
