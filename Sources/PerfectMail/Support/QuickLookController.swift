import AppKit
import Quartz

/// Minimal bridge to the system Quick Look panel: hold the item list, act as
/// its data source, order it front. Esc/space dismisses it as usual.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var urls: [URL] = []

    func show(_ urls: [URL], startingAt index: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.currentPreviewItemIndex = min(index, urls.count - 1)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!,
                                  previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
