import Testing
import Foundation
@testable import Ghostty

/// Integration tests for GitPanelModel. Each test builds a real throwaway
/// git repository under a temporary directory and drives the model against
/// it, which exercises repo discovery, `status --porcelain` parsing, and the
/// checkout/commit/discard actions end to end.
@MainActor
struct GitPanelModelTests {
    final class TempRepo {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ghostty-gitpanel-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try git("init", "-q", "-b", "main")
            try git("config", "user.email", "test@example.com")
            try git("config", "user.name", "Test")
            // Keep porcelain output deterministic for non-ASCII paths.
            try git("config", "core.quotepath", "false")
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func git(_ args: String..., env: [String: String] = [:]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            if !env.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(env) { _, new in new }
            }
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GitError.commandFailed(args.joined(separator: " "))
            }
            return String(data: data, encoding: .utf8) ?? ""
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(
                to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func read(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }

        func commit(_ message: String = "commit") throws {
            try git("add", "-A")
            try git("commit", "-q", "-m", message)
        }

        enum GitError: Error {
            case commandFailed(String)
        }
    }

    /// The model's actions complete in a detached Task with no completion
    /// signal, so tests poll for their effect.
    func waitUntil(
        timeout: TimeInterval = 10,
        _ comment: Comment,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for: \(comment)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func makeModel(_ repo: TempRepo) async -> GitPanelModel {
        let model = GitPanelModel()
        model.pwd = repo.root.path
        await model.refresh()
        return model
    }

    // MARK: - Repo discovery and status parsing

    @Test func nonRepoDirectoryYieldsNoState() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty-nonrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = GitPanelModel()
        model.pwd = dir.path
        await model.refresh()

        #expect(model.repoRoot == nil)
        #expect(model.branch == nil)
        #expect(model.changes.isEmpty)
    }

    @Test func repoRootIsFoundFromASubdirectory() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "a")
        try repo.commit()
        let sub = repo.root.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let model = GitPanelModel()
        model.pwd = sub.path
        await model.refresh()

        // Compare resolved path strings: /tmp may be a symlink to
        // /private/tmp, and URL equality trips on trailing slashes.
        let got = URL(fileURLWithPath: model.repoRoot ?? "").resolvingSymlinksInPath().path
        #expect(got == repo.root.resolvingSymlinksInPath().path)
        #expect(model.branch == "main")
    }

    @Test func cleanRepoOnFreshBranchHasNoChanges() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "a")
        try repo.commit()

        let model = await makeModel(repo)

        #expect(model.branch == "main")
        #expect(model.changes.isEmpty)
        #expect(!model.isDetached)
        #expect(!model.hasUpstream)
        #expect(model.branches == ["main"])
    }

    @Test func statusReflectsUntrackedModifiedAndDeleted() async throws {
        let repo = try TempRepo()
        try repo.write("modified.txt", "v1")
        try repo.write("deleted.txt", "gone soon")
        try repo.commit()

        try repo.write("modified.txt", "v2")
        try repo.write("untracked.txt", "new")
        try repo.git("rm", "-q", "deleted.txt")

        let model = await makeModel(repo)

        let byPath = Dictionary(uniqueKeysWithValues: model.changes.map { ($0.path, $0.status) })
        #expect(byPath["modified.txt"] == "M")
        #expect(byPath["untracked.txt"] == "?")
        #expect(byPath["deleted.txt"] == "D")
    }

    @Test func stagedRenameKeepsOriginalPath() async throws {
        let repo = try TempRepo()
        try repo.write("old.txt", "content")
        try repo.commit()
        try repo.git("mv", "old.txt", "new.txt")

        let model = await makeModel(repo)

        let rename = model.changes.first { $0.path == "new.txt" }
        #expect(rename != nil)
        #expect(rename?.status == "R")
        #expect(rename?.origPath == "old.txt")
    }

    @Test func detachedHeadIsReported() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "a")
        try repo.commit()
        try repo.git("checkout", "-q", "--detach")

        let model = await makeModel(repo)

        #expect(model.isDetached)
        #expect(model.branch == nil)
    }

    @Test func emptyRepoReportsUnbornBranch() async throws {
        let repo = try TempRepo()

        let model = await makeModel(repo)

        #expect(model.branch == "main")
        #expect(model.changes.isEmpty)
    }

    @Test func aheadBehindCountsAgainstUpstream() async throws {
        let upstream = try TempRepo()
        try upstream.git("config", "receive.denyCurrentBranch", "ignore")
        try upstream.write("a.txt", "a")
        try upstream.commit()

        let repo = try TempRepo()
        try repo.git("remote", "add", "origin", upstream.root.path)
        try repo.git("fetch", "-q", "origin")
        try repo.git("checkout", "-q", "-B", "main", "--track", "origin/main")

        try repo.write("b.txt", "b")
        try repo.commit("local work")

        let model = await makeModel(repo)

        #expect(model.hasUpstream)
        #expect(model.ahead == 1)
        #expect(model.behind == 0)
    }

    @Test func branchListIsSortedByRecency() async throws {
        let repo = try TempRepo()
        // Commit dates are pinned: for-each-ref sorts by committerdate, and
        // two commits landing in the same second would make the order flaky.
        try repo.write("a.txt", "a")
        try repo.git("add", "-A")
        try repo.git("commit", "-q", "-m", "base",
                     env: ["GIT_COMMITTER_DATE": "2026-01-01T12:00:00",
                           "GIT_AUTHOR_DATE": "2026-01-01T12:00:00"])
        try repo.git("branch", "older")
        try repo.git("checkout", "-q", "-b", "newer")
        try repo.write("b.txt", "b")
        try repo.git("add", "-A")
        try repo.git("commit", "-q", "-m", "newer work",
                     env: ["GIT_COMMITTER_DATE": "2026-01-02T12:00:00",
                           "GIT_AUTHOR_DATE": "2026-01-02T12:00:00"])

        let model = await makeModel(repo)

        #expect(model.branches.contains("main"))
        #expect(model.branches.contains("older"))
        #expect(model.branches.first == "newer")
    }

    // MARK: - Actions

    @Test func checkoutSwitchesBranch() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "a")
        try repo.commit()
        try repo.git("branch", "feature")

        let model = await makeModel(repo)
        model.checkout("feature")
        try await waitUntil("checkout to land") { model.branch == "feature" && !model.isBusy }

        #expect(model.errorMessage == nil)
        #expect(try repo.git("rev-parse", "--abbrev-ref", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "feature")
    }

    @Test func checkoutFailureSurfacesAnError() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "a")
        try repo.commit()

        let model = await makeModel(repo)
        model.checkout("does-not-exist")
        try await waitUntil("error to surface") { model.errorMessage != nil }

        #expect(model.branch == "main")
    }

    @Test func createBranchSwitchesToIt() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "a")
        try repo.commit()

        let model = await makeModel(repo)
        model.createBranch("experiment")
        try await waitUntil("branch creation") { model.branch == "experiment" && !model.isBusy }

        #expect(model.errorMessage == nil)
    }

    @Test func commitAllStagesAndCommitsEverything() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "a")
        try repo.commit()
        try repo.write("a.txt", "changed")
        try repo.write("new.txt", "brand new")

        let model = await makeModel(repo)
        model.commitAll(message: "  sidebar commit  ")
        try await waitUntil("commit to land") { model.changes.isEmpty && !model.isBusy }

        #expect(model.errorMessage == nil)
        let subject = try repo.git("log", "-1", "--format=%s")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(subject == "sidebar commit")
    }

    @Test func commitAllIgnoresEmptyMessage() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "a")
        try repo.commit()
        try repo.write("a.txt", "changed")

        let model = await makeModel(repo)
        model.commitAll(message: "   \n  ")

        #expect(!model.isBusy)
        await model.refresh()
        #expect(model.changes.map(\.path) == ["a.txt"])
    }

    @Test func discardModifiedFileRestoresContent() async throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "original")
        try repo.commit()
        try repo.write("a.txt", "scribbled")

        let model = await makeModel(repo)
        let change = try #require(model.changes.first { $0.path == "a.txt" })
        model.discard(change)
        try await waitUntil("discard to land") { model.changes.isEmpty && !model.isBusy }

        #expect(try repo.read("a.txt") == "original")
    }

    @Test func discardUntrackedFileDeletesIt() async throws {
        let repo = try TempRepo()
        try repo.write("keep.txt", "keep")
        try repo.commit()
        try repo.write("junk.txt", "delete me")

        let model = await makeModel(repo)
        let change = try #require(model.changes.first { $0.path == "junk.txt" })
        model.discard(change)
        try await waitUntil("untracked file removal") { !repo.exists("junk.txt") }

        #expect(repo.exists("keep.txt"))
    }

    @Test func discardStagedRenameRestoresOriginal() async throws {
        let repo = try TempRepo()
        try repo.write("old.txt", "content")
        try repo.commit()
        try repo.git("mv", "old.txt", "new.txt")

        let model = await makeModel(repo)
        let change = try #require(model.changes.first { $0.path == "new.txt" })
        model.discard(change)
        try await waitUntil("rename discard") {
            repo.exists("old.txt") && !repo.exists("new.txt")
        }

        #expect(try repo.read("old.txt") == "content")
    }

    @Test func discardAllResetsTrackedAndDeletesUntracked() async throws {
        let repo = try TempRepo()
        try repo.write("tracked.txt", "original")
        try repo.commit()
        try repo.write("tracked.txt", "dirty")
        try repo.write("untracked.txt", "junk")

        let model = await makeModel(repo)
        model.discardAll()
        try await waitUntil("discard all") { model.changes.isEmpty && !model.isBusy }

        #expect(try repo.read("tracked.txt") == "original")
        #expect(!repo.exists("untracked.txt"))
    }
}
