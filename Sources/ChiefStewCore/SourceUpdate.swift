import Foundation

/// "Is there a newer Chief Stew?" for a copy built from a local checkout: has `main` in the
/// source folder moved past the commit this copy was built from? Read-only git, no network.
public enum SourceUpdate {
    public struct Available: Sendable, Equatable {
        /// Commits on main since the installed build; nil when the installed commit is unknown
        /// to the repo (history was rewritten).
        public var newCommits: Int?
        /// main's commit now; one notification per value.
        public var latest: String
    }

    public static let branch = "main"

    /// - Parameter installedCommit: `ChiefStewSourceCommit` from Info.plist; a `-dirty` suffix
    ///   means the build had uncommitted changes on top of that commit.
    public static func check(
        sourceDir: String, installedCommit: String, git: String = "/usr/bin/git"
    ) async -> Available? {
        let installed = installedCommit.replacingOccurrences(of: "-dirty", with: "")
        let env = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        func run(_ args: [String]) async -> String? {
            guard
                let r = try? await CommandRunner.run(
                    git, ["-C", sourceDir] + args, environment: env, timeout: 10),
                r.exitCode == 0, !r.timedOut
            else { return nil }
            return String(decoding: r.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let main = await run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]),
            !main.isEmpty
        else { return nil }
        if main == installed { return nil }
        guard await run(["cat-file", "-e", "\(installed)^{commit}"]) != nil else {
            return Available(newCommits: nil, latest: main)
        }
        guard let count = await run(["rev-list", "--count", "\(installed)..\(main)"]).flatMap(Int.init),
            count > 0
        else { return nil }  // built from a commit ahead of main (a branch): nothing newer
        return Available(newCommits: count, latest: main)
    }
}

// MARK: - Releases (the team channel)

extension SourceUpdate {
    /// A tagged release: `v0.3.0`, its version, and the notes in the tag's message.
    public struct Release: Sendable, Equatable {
        public var tag: String
        public var version: String
        public var notes: String
    }

    /// Updates are a progressive enhancement: only a copy built from a git clone can update
    /// itself. A copy from a downloaded zip works fully but never updates.
    public static func isClone(_ sourceDir: String) -> Bool {
        FileManager.default.fileExists(atPath: (sourceDir as NSString).appendingPathComponent(".git"))
    }

    /// Fetches tags (and origin's branches) into Chief Stew's own source clone: its only network
    /// access. Never touches the checked-out branch or files. False when offline or without
    /// access, which is fine: there's simply no update.
    /// `path`: the login shell's PATH, so credential helpers installed with Homebrew etc. work.
    public static func fetch(sourceDir: String, path: String = "/usr/bin:/bin", git: String = "/usr/bin/git") async -> Bool {
        guard isClone(sourceDir),
            let r = try? await CommandRunner.run(
                git, ["-C", sourceDir, "fetch", "--quiet", "--tags", "origin"],
                environment: [
                    "GIT_OPTIONAL_LOCKS": "0", "PATH": path, "HOME": NSHomeDirectory(),
                    "GIT_TERMINAL_PROMPT": "0",  // never block on a password prompt
                ],
                timeout: 60)
        else { return false }
        return r.exitCode == 0 && !r.timedOut
    }

    /// The newest `vX.Y.Z` tag in the clone, with its notes.
    public static func latestRelease(sourceDir: String, git: String = "/usr/bin/git") async -> Release? {
        guard isClone(sourceDir),
            let r = try? await CommandRunner.run(
                git, ["-C", sourceDir, "tag", "--list", "v*"],
                environment: ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                timeout: 10),
            r.exitCode == 0
        else { return nil }
        let tags = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { parse(String($0.dropFirst())) != nil }
        guard let tag = tags.max(by: { compare(String($0.dropFirst()), String($1.dropFirst())) < 0 }) else { return nil }
        let notes = (try? await CommandRunner.run(
            git, ["-C", sourceDir, "tag", "--list", "--format=%(contents:body)", tag],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: 10))
            .map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return Release(tag: tag, version: String(tag.dropFirst()), notes: notes)
    }

    /// `0.10.0` > `0.9.2`; nil for anything that isn't `X.Y.Z`.
    public static func parse(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    public static func compare(_ a: String, _ b: String) -> Int {
        guard let x = parse(a), let y = parse(b) else { return a == b ? 0 : (a < b ? -1 : 1) }
        for (p, q) in zip(x, y) where p != q { return p < q ? -1 : 1 }
        return 0
    }
}
