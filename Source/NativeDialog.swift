import AppKit

extension NSWindow {
    var hasDocumentDialog: Bool { attachedSheet != nil || childWindows?.contains { $0.identifier?.rawValue == "UVZDocumentDialog" && $0.isVisible } == true }
    func bringDocumentDialogForward() { childWindows?.last(where: { $0.identifier?.rawValue == "UVZDocumentDialog" })?.makeKeyAndOrderFront(nil) }
}

/// Native titled windows can move independently; attached sheets cannot.
enum NativeDialog {
    static func present(_ window: NSWindow, on parent: NSWindow) {
        window.identifier = .init("UVZDocumentDialog")
        window.isMovable = true; window.isMovableByWindowBackground = false
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        var frame = window.frame
        frame.size.width = min(frame.width, screen.width - 32)
        frame.size.height = min(frame.height, screen.height - 32)
        frame.origin = CGPoint(x: min(screen.maxX-frame.width-16, max(screen.minX+16, parent.frame.midX-frame.width/2)), y: min(screen.maxY-frame.height-16, max(screen.minY+16, parent.frame.midY-frame.height/2)))
        window.setFrame(frame, display: false)
        parent.addChildWindow(window, ordered: .above); window.makeKeyAndOrderFront(nil)
    }
    static func dismiss(_ window: NSWindow) {
        window.childWindows?.forEach { dismiss($0) }
        let parent = window.parent
        parent?.removeChildWindow(window)
        if let sheetParent = window.sheetParent { sheetParent.endSheet(window) }
        window.orderOut(nil); parent?.makeKeyAndOrderFront(nil)
    }
    static func alert(_ alert: NSAlert, on parent: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        // NSAlert retains Apple's standard buttons, accessibility and keyboard behavior.
        alert.window.isMovable = true; alert.window.isMovableByWindowBackground = true
        alert.window.center()
        let response = alert.runModal(); alert.window.orderOut(nil); parent.makeKeyAndOrderFront(nil); completion(response)
    }
}
