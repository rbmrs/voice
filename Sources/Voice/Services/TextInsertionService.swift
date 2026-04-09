import AppKit
import ApplicationServices
import Foundation

@MainActor
final class TextInsertionService {
    func insert(text: String, mode: TextInsertionMode) async throws {
        guard AXIsProcessTrusted() else {
            throw DictationServiceError.permission("Accessibility access is required to insert text.")
        }

        switch mode {
        case .pasteboard:
            try await pasteUsingPasteboard(text)
        case .keystrokes:
            try typeUsingUnicodeEvents(text)
        }
    }

    private func pasteUsingPasteboard(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw DictationServiceError.insertionFailure("The pasteboard could not be updated for insertion.")
        }

        try postKeyPress(keyCode: 9, flags: .maskCommand)

        try? await Task.sleep(for: .milliseconds(250))
        snapshot.restore(to: pasteboard)
    }

    private func typeUsingUnicodeEvents(_ text: String) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw DictationServiceError.insertionFailure("The system input source could not be created.")
        }

        let characters: [UniChar] = Array(text.utf16)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw DictationServiceError.insertionFailure("Unicode key events could not be created.")
        }

        keyDown.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        keyUp.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func postKeyPress(keyCode: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw DictationServiceError.insertionFailure("The system input source could not be created.")
        }

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw DictationServiceError.insertionFailure("The paste keyboard event could not be created.")
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }

        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !items.isEmpty else { return }

        let restoredItems = items.map { itemData -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
    }
}
