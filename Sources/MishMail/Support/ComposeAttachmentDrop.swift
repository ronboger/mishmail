import AppKit
import UniformTypeIdentifiers

/// Pure helpers for turning Finder (and other-app) file drops into compose
/// attachments. AppKit pasteboard + URL dedupe live here so unit tests can
/// cover the merge rules without spinning up ComposeView.
enum ComposeAttachmentDrop {
    /// True when the pasteboard carries at least one file URL (not a plain
    /// text/URL string drop).
    static func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        !fileURLs(from: pasteboard).isEmpty
    }

    /// File URLs currently on the pasteboard (Finder drag, etc.).
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return (urls ?? []).filter { $0.isFileURL }
    }

    /// Append `incoming` onto `existing`, skipping path-duplicates (same file
    /// dragged twice) while preserving order of first appearance.
    static func dedupeAppend(existing: [URL], incoming: [URL]) -> [URL] {
        var seen = Set(existing.map(\.standardizedFileURL.path))
        var out = existing
        for url in incoming where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(url)
        }
        return out
    }

    /// Outcome of merging newly loaded drop attachments into the chip list
    /// by filename (bytes are already detached from paths at this point).
    struct FilenameMerge: Equatable {
        var added: [String]
        var skippedDuplicate: Int
        var failedReads: Int
    }

    /// Filenames to append that are not already on the draft. Pure so tests
    /// pin the silent-drop behavior Fable flagged on re-drop / same name.
    static func mergeNewFilenames(existing: Set<String>,
                                  incoming: [String],
                                  failedReads: Int = 0) -> FilenameMerge {
        var seen = existing
        var added: [String] = []
        var skipped = 0
        for name in incoming {
            if seen.contains(name) {
                skipped += 1
                continue
            }
            seen.insert(name)
            added.append(name)
        }
        return FilenameMerge(added: added, skippedDuplicate: skipped, failedReads: failedReads)
    }

    /// User-facing note when some dropped files couldn't be attached.
    /// Nil when everything added cleanly.
    static func dropStatusMessage(merge: FilenameMerge, attempted: Int) -> String? {
        guard attempted > 0 else { return nil }
        if merge.added.isEmpty, merge.failedReads == attempted {
            return "Couldn't read the dropped file\(attempted == 1 ? "" : "s")."
        }
        if merge.added.isEmpty, merge.skippedDuplicate == attempted {
            return attempted == 1
                ? "Already attached."
                : "Those files are already attached."
        }
        var parts: [String] = []
        if merge.failedReads > 0 {
            parts.append(merge.failedReads == 1
                         ? "1 file couldn't be read"
                         : "\(merge.failedReads) files couldn't be read")
        }
        if merge.skippedDuplicate > 0 {
            parts.append(merge.skippedDuplicate == 1
                         ? "1 already attached"
                         : "\(merge.skippedDuplicate) already attached")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + "."
    }

    /// Load file URLs from SwiftUI/NSItemProvider drops (async providers).
    /// Preserves provider order (indexed slots) so multi-file drops don't
    /// reorder when loadItem completions race.
    static func fileURLs(from providers: [NSItemProvider],
                         completion: @escaping ([URL]) -> Void) {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            completion([])
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var slots: [URL?] = Array(repeating: nil, count: fileProviders.count)
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let u = item as? NSURL {
                    url = u as URL
                } else {
                    url = nil
                }
                guard let url, url.isFileURL else { return }
                lock.lock()
                slots[index] = url
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            completion(slots.compactMap { $0 })
        }
    }
}
