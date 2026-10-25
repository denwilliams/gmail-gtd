import AppKit
import SwiftUI

/// Menu key equivalents alone lose to a focused List's type-to-select handling.
/// Intercept approval before AppKit dispatches the key to that list, only in the mail window.
struct ApprovalShortcutHandler: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> ApprovalShortcutView {
        let view = ApprovalShortcutView()
        view.model = model
        return view
    }

    func updateNSView(_ view: ApprovalShortcutView, context: Context) { view.model = model }

    static func dismantleNSView(_ view: ApprovalShortcutView, coordinator: ()) {
        view.stopMonitoring()
    }
}

@MainActor
final class ApprovalShortcutView: NSView {
    weak var model: AppModel?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returning nil consumes the key: it must not also select a row or invoke the menu action.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown,
              event.charactersIgnoringModifiers?.lowercased() == "a",
              event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
              let window, event.window === window,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !Self.isEditing(window.firstResponder),
              let model, model.signedIn, !model.showingCategorisationSettings, model.deNoiseBatch == nil,
              let id = model.selection, model.detail?.id == id,
              let bucket = model.approvalBucket else { return event }

        // Holding A must not approve a stream of newly selected threads.
        if !event.isARepeat {
            Task { [weak model] in
                guard let model, model.signedIn, model.selection == id, model.detail?.id == id,
                      !model.showingCategorisationSettings, model.deNoiseBatch == nil,
                      model.approvalBucket == bucket else { return }
                await model.acceptSuggestion()
            }
        }
        return nil
    }

    private static func isEditing(_ responder: NSResponder?) -> Bool {
        var current = responder
        while let responder = current {
            if let text = responder as? NSTextView, text.isEditable { return true }
            if let field = responder as? NSTextField, field.isEditable { return true }
            current = responder.nextResponder
        }
        return false
    }
}
