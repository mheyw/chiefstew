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

    /// Repos to suggest, without touching macOS-protected folders (see RepoSuggestions).
    static func suggestions() -> [String] { RepoSuggestions.find() }
}
