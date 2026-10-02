import Foundation

/// Git repos to suggest in the Add Repo wizard, found without ever touching the folders macOS
/// protects (Desktop, Documents, Downloads, iCloud Drive, …): looking inside those raises a
/// permission prompt just to fill a menu. A repo there can still be added with Choose…, since
/// picking it in the Open dialog grants access.
public enum RepoSuggestions {
    /// Home-folder children macOS guards with a permission prompt (or that are never repos).
    public static let protected: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Public",
        "Applications", "iCloud Drive (Archive)", "Mobile Documents",
    ]
    /// Where people usually keep code, checked one level deep.
    public static let roots = ["Developer", "Projects", "Code", "code", "src", "GitHub", "repos", "Sites", "workspace", "dev"]

    public static func find(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        func consider(_ path: String) {
            if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")), !found.contains(path) {
                found.append(path)
            }
        }
        let topLevel = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") && !protected.contains($0) }
        // Repos directly in the home folder (~/my-app), skipping protected folders entirely.
        for child in topLevel { consider((home as NSString).appendingPathComponent(child)) }
        // And one level inside the usual code folders.
        for root in roots where topLevel.contains(root) {
            let dir = (home as NSString).appendingPathComponent(root)
            for child in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !child.hasPrefix(".") {
                consider((dir as NSString).appendingPathComponent(child))
            }
        }
        // Repos already set up for Chief Stew first.
        func ready(_ p: String) -> Bool {
            fm.fileExists(atPath: (p as NSString).appendingPathComponent(RepoConfig.fileName))
        }
        return found.filter(ready) + found.filter { !ready($0) }
    }
}
