import AppKit
import Testing
@testable import GmailGTD
@testable import GTDCore

private enum ShortcutTestError: Error { case unavailable }

/// Observe delivery to the native list, not just whether the model's approval method works.
@MainActor private final class ShortcutTable: NSTableView, NSTableViewDataSource {
    var deliveredKeys = 0
    override func keyDown(with event: NSEvent) {
        deliveredKeys += 1
        super.keyDown(with: event)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { 2 }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        row == 0 ? "Zebra selected thread" : "Alpha other thread"
    }
}

@MainActor private final class ShortcutWindow {
    let window: NSWindow
    let handler = ApprovalShortcutView()
    let table = ShortcutTable()

    init(model: AppModel) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        handler.model = model
        window.contentView?.addSubview(handler)
        table.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject")))
        table.dataSource = table
        table.allowsTypeSelect = true
        window.contentView?.addSubview(table)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
    }

    func event(_ characters: String = "a", modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: repeatKey, keyCode: 0))
    }

    func close() {
        handler.removeFromSuperview()   // Also removes the local event monitor.
        window.close()
    }
}

@MainActor private func shortcutEventually(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition(), "Timed out waiting for shortcut approval")
}

@MainActor private func shortcutModel(jevEnabled: Bool = false, remoteSucceeds: Bool = true) async throws -> AppModel {
    var settings = CategorisationSettings(); settings.jevEnabled = jevEnabled
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: Categoriser(local: { _, _, _ in
        TriageSuggestion(bucket: .reference, nextAction: "", summary: "Local summary.")
    }, remote: { _, _, _, _ in
        guard remoteSucceeds else { throw ShortcutTestError.unavailable }
        return .noise
    }), loadJevToken: { "mock-token" })
    model.demo = true
    await model.connect(using: DemoMailService(), persist: false)
    try await shortcutEventually { model.detail?.id == model.selection && model.suggestion != nil && !model.suggesting }
    return model
}

// All tests share AppKit's key-window/first-responder state, so do not run them concurrently.
@Suite(.serialized) @MainActor struct ApprovalShortcutTests {
    @Test(arguments: [false, true])
    func focusedListApprovesSelectedThreadAndConsumesEvent(jevEnabled: Bool) async throws {
        let model = try await shortcutModel(jevEnabled: jevEnabled)
        defer { model.signOut() }
        let selectedID = try #require(model.selection)
        let fixture = ShortcutWindow(model: model)
        defer { fixture.close() }
        #expect(fixture.window.firstResponder === fixture.table)

        // Use the real local monitor installed by viewDidMoveToWindow and AppKit dispatch.
        NSApplication.shared.sendEvent(try fixture.event())
        #expect(fixture.table.deliveredKeys == 0)
        #expect(fixture.table.selectedRow == 0)   // A did not jump to the Alpha row.
        try await shortcutEventually { model.undoStack.count == 1 }
        #expect(model.undoStack.first?.threadID == selectedID)
        #expect(model.undoStack.first?.destination == (jevEnabled ? .noise : .reference))
        #expect(!model.rows.contains { $0.id == selectedID })
        await model.refreshQuietly()   // Wait for the same normal filing path to finish.
        #expect(model.error == nil)
    }

    @Test func disabledApprovalDoesNotFallBackToLocalOrApproveAnotherThread() async throws {
        let model = try await shortcutModel(jevEnabled: true, remoteSucceeds: false)
        defer { model.signOut() }
        let selectedID = model.selection
        let fixture = ShortcutWindow(model: model)
        defer { fixture.close() }
        #expect(model.suggestion != nil)
        #expect(model.approvalBucket == nil)
        let event = try fixture.event()
        #expect(fixture.handler.handle(event) === event)
        await Task.yield()
        #expect(model.undoStack.isEmpty)
        #expect(model.selection == selectedID)

        model.selection = nil
        #expect(fixture.handler.handle(event) === event)
        #expect(model.undoStack.isEmpty)
    }

    @Test func editableFocusKeepsNormalTyping() async throws {
        let model = try await shortcutModel()
        defer { model.signOut() }
        let fixture = ShortcutWindow(model: model)
        defer { fixture.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 210, width: 200, height: 60))
        fixture.window.contentView?.addSubview(editor)
        fixture.window.makeFirstResponder(editor)
        #expect(fixture.window.firstResponder === editor)
        NSApplication.shared.sendEvent(try fixture.event())
        #expect(editor.string == "a")

        // TextField and SecureField use AppKit's shared NSTextView field editor.
        for field in [NSTextField(), NSSecureTextField()] {
            field.frame = editor.frame
            fixture.window.contentView?.addSubview(field)
            field.selectText(nil)
            #expect(fixture.window.firstResponder is NSTextView)
            NSApplication.shared.sendEvent(try fixture.event())
            #expect(field.stringValue == "a")
            field.removeFromSuperview()
        }
        await Task.yield()
        #expect(model.undoStack.isEmpty)
    }

    @Test func modifiedKeysOtherWindowsAndModalContextsPassThrough() async throws {
        let model = try await shortcutModel()
        defer { model.signOut() }
        let fixture = ShortcutWindow(model: model)
        defer { fixture.close() }
        for modifiers in [NSEvent.ModifierFlags.command, .control, .option, .function] {
            let event = try fixture.event(modifiers: modifiers)
            #expect(fixture.handler.handle(event) === event)   // Especially Cmd+A: Select All.
        }
        let other = ShortcutWindow(model: model)
        defer { other.close() }
        let otherEvent = try other.event()
        #expect(fixture.handler.handle(otherEvent) === otherEvent)
        let event = try fixture.event()
        model.showingCategorisationSettings = true
        #expect(fixture.handler.handle(event) === event)
        model.showingCategorisationSettings = false
        model.detail = nil   // Never act on stale detail while the selected thread loads.
        #expect(fixture.handler.handle(event) === event)
        await Task.yield()
        #expect(model.undoStack.isEmpty)
    }

    @Test func repeatedKeyDoesNotApproveAndDetachedHandlerStopsIntercepting() async throws {
        let model = try await shortcutModel()
        defer { model.signOut() }
        let fixture = ShortcutWindow(model: model)
        defer { fixture.close() }
        NSApplication.shared.sendEvent(try fixture.event(repeatKey: true))
        #expect(fixture.table.deliveredKeys == 0)
        await Task.yield()
        #expect(model.undoStack.isEmpty)
        fixture.handler.removeFromSuperview()
        NSApplication.shared.sendEvent(try fixture.event())
        #expect(fixture.table.deliveredKeys == 1)
        await Task.yield()
        #expect(model.undoStack.isEmpty)
    }
}
