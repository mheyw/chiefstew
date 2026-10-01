import Foundation
import os

/// Reads the inbox folder: parses each event file, deletes it, returns what was valid.
/// See docs/event-contract.md § 3.4.
public enum InboxReader {
    public static let maxAge: TimeInterval = 24 * 3600
    private static let log = Logger(subsystem: "com.mheyw.chiefstew", category: "inbox")

    public struct Rejected: Sendable, Equatable {
        public var file: String
        public var reason: String
    }

    public struct Result: Sendable {
        public var events: [Event] = []
        public var rejected: [Rejected] = []
        public var expired = 0
    }

    /// Handle every `*.json` file in `dir` (dotfiles are in-progress writes), oldest first.
    public static func drain(_ dir: URL, now: Date = Date()) -> Result {
        var result = Result()
        let fm = FileManager.default
        guard
            let names = try? fm.contentsOfDirectory(atPath: dir.path)
                .filter({ !$0.hasPrefix(".") && $0.hasSuffix(".json") })
        else { return result }

        var parsed: [(event: Event, name: String)] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            defer { try? fm.removeItem(at: url) }
            let attributes = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            // Only plain files: opening a FIFO would block forever, and a symlink could point
            // anywhere (review: inbox-fifo-hang). attributesOfItem doesn't follow symlinks.
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                result.rejected.append(.init(file: name, reason: "not a regular file"))
                continue
            }
            let mtime = attributes[.modificationDate] as? Date ?? now
            let data: Data
            do {
                // Read at most one byte past the limit so a huge file can't be slurped.
                let handle = try FileHandle(forReadingFrom: url)
                data = try handle.read(upToCount: Event.maxBytes + 1) ?? Data()
                try? handle.close()
            } catch {
                result.rejected.append(.init(file: name, reason: "unreadable: \(error)"))
                continue
            }
            do {
                let event = try Event.parse(data, fallbackDate: mtime)
                if now.timeIntervalSince(event.ts) > maxAge {
                    result.expired += 1
                } else {
                    parsed.append((event, name))
                }
            } catch {
                let head = String(decoding: data.prefix(200), as: UTF8.self)
                log.error("rejected \(name, privacy: .public): \(String(describing: error), privacy: .public) — \(head, privacy: .public)")
                result.rejected.append(.init(file: name, reason: String(describing: error)))
            }
        }
        result.events = parsed.sorted { ($0.event.ts, $0.name) < ($1.event.ts, $1.name) }.map(\.event)
        return result
    }
}

/// Calls `onChange` when files are added to the inbox folder. A kqueue vnode source on the
/// folder: cheaper than FSEvents for one flat folder. If the folder is deleted or replaced, the
/// watch stops; `ensureRunning()` (called from the poll loop) re-creates it.
public final class InboxWatcher: @unchecked Sendable {
    private let dir: URL
    private let queue = DispatchQueue(label: "chiefstew.inbox")
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?  // touched only on `queue`

    public init(dir: URL, onChange: @escaping @Sendable () -> Void) {
        self.dir = dir
        self.onChange = onChange
    }

    public func ensureRunning() {
        queue.async { [self] in
            if source == nil { startLocked() }
        }
    }

    public func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
        }
    }

    private func startLocked() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                src.cancel()
                self.source = nil
                return
            }
            self.onChange()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }
}
