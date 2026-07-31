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

    /// Load file URLs from SwiftUI/NSItemProvider drops (async providers).
    /// Returns immediately-available URLs; callers that need security-scoped
    /// access should `startAccessingSecurityScopedResource` when reading.
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
        var collected: [URL] = []
        for provider in fileProviders {
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
                collected.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            completion(collected)
        }
    }
}
