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
