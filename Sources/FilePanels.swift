import AppKit

/// Completion-based panels keep Swift's main actor free to process UI and media tasks.
@MainActor
enum FilePanels {
    private static var active: NSSavePanel?
    static func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard active == nil else { active?.makeKeyAndOrderFront(nil); return }
        active = panel
        let finished: (NSApplication.ModalResponse) -> Void = { response in
            active = nil
            completion(response)
        }
        let parent = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first { !($0 is NSPanel) && $0.isVisible }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: finished) }
        else { panel.begin(completionHandler: finished) }
    }
}
