import Foundation

/// Locations of the application's persisted data.
///
/// Files are stored under Application Support rather than a hidden directory,
/// since the dictionary is intended to be discoverable and editable by hand.
enum Storage {
    /// Resolved once. It was previously computed on every access, so a SwiftUI
    /// view body that mentioned a file path ran directory creation and a
    /// migration check on every redraw.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Brand.productName, not Brand.name — the display name has a "?" in it.
        let dir = base.appendingPathComponent(Brand.productName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyDataIfNeeded(into: dir, from: base)
        return dir
    }()

    /// Migrates data from a previous product name. Renaming the application
    /// must not orphan an existing dictionary or history.
    /// Runs at most once, ever.
    ///
    /// This used to run on every access to `directory`, copying anything the
    /// destination lacked. That made deletion ineffective: a user who removed
    /// `history.json` to purge sensitive transcripts had them restored from the
    /// old location on the next launch. A marker records that the migration has
    /// happened so it cannot silently undo a deletion.
    private static func migrateLegacyDataIfNeeded(into dir: URL, from base: URL) {
        let done = "didMigrateLegacyData"
        guard !UserDefaults.standard.bool(forKey: done) else { return }
        UserDefaults.standard.set(true, forKey: done)

        let fm = FileManager.default
        let legacy = base.appendingPathComponent(Brand.legacyProductName, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }

        for name in ["dictionary.json", "history.json", "people.json", "decisions.json"] {
            let source = legacy.appendingPathComponent(name)
            let destination = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
                Log.app.info("migrated \(name, privacy: .public) from the previous product name")
            } catch {
                Log.app.error("migration of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static var dictionaryURL: URL { directory.appendingPathComponent("dictionary.json") }
    static var historyURL: URL { directory.appendingPathComponent("history.json") }
    /// Names, held apart from the dictionary. See `PeopleStore`.
    static var peopleURL: URL { directory.appendingPathComponent("people.json") }
    /// Every token the analysis pass has already asked about. See
    /// `DecisionLedger`.
    static var decisionsURL: URL { directory.appendingPathComponent("decisions.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Sorted keys and pretty printing keep hand-edited files diff-stable
        // across saves.
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Observes a single file for external modification so that edits made in a
/// text editor are reflected without relaunching.
///
/// Most editors replace files by rename rather than writing in place, which
/// invalidates the file descriptor; `.delete` and `.rename` therefore re-arm the
/// watch on a fresh descriptor.
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let url: URL
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    private func start() {
        stop()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Allow the replacing editor to complete before re-arming.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.start()
                    self.onChange()
                }
            } else {
                self.onChange()
            }
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
    }

    private func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
