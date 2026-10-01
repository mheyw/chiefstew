import ChiefStewCore
import Foundation

/// The registered repos. UserDefaults `repos`; `$CHIEFSTEW_REPOS` (colon-separated) overrides it
/// for dev runs. Nothing is registered automatically: the Add Repo wizard suggests git repos it
/// finds, and the owner picks (review: autoseed-executes-unreviewed-repos).
enum RepoStore {
    static let key = "repos"

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> [String] {
        if let override = environment["CHIEFSTEW_REPOS"] {
            return override.split(separator: ":").map { PathMatch.normalize(String($0)) }
        }
        return defaults.stringArray(forKey: key) ?? []
    }

    /// Git repos in the usual places (~/Developer, ~/Projects, ~/Code, ~/src, ~/GitHub, and
    /// the home folder itself), one level deep. Repos already set up for Chief Stew come first.
    static func suggestions() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["Developer", "Projects", "Code", "src", "GitHub", "Documents/GitHub", ""]
            .map { $0.isEmpty ? home : (home as NSString).appendingPathComponent($0) }
        var found: [String] = []
        for root in roots {
            for child in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted()
            where !child.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(child)
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")),
                    !found.contains(path)
                {
                    found.append(path)
                }
            }
        }
        func ready(_ p: String) -> Bool {
            if case .success(let c) = RepoConfig.load(repo: p) { return c.source != .none }
            return true
        }
        return found.filter(ready) + found.filter { !ready($0) }
    }
}
