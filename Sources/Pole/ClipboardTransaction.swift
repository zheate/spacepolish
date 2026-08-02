import AppKit
import Foundation

/// A best-effort transaction around the shared system pasteboard.
///
/// Pole restores the user's previous clipboard only while the temporary
/// contents are still marked as being owned by this transaction. Any copy made
/// by the user or another application removes the marker or changes the
/// pasteboard revision, so that content is left untouched.
final class ClipboardTransaction {
    static let markerType = NSPasteboard.PasteboardType(
        "com.spacepolish.clipboard-transaction"
    )

    private let pasteboard: NSPasteboard
    private let originalContents: PasteboardContents
    private let markerData: Data
    private var ownedChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.originalContents = PasteboardContents(pasteboard: pasteboard)
        self.markerData = Data(UUID().uuidString.utf8)
    }

    @discardableResult
    func writeString(_ string: String) -> Bool {
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        item.setData(markerData, forType: Self.markerType)

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            ownedChangeCount = nil
            return false
        }
        ownedChangeCount = pasteboard.changeCount
        return true
    }

    /// Rewrites the current items unchanged while attaching Pole's ownership
    /// marker. This is used after the target application has completed Copy.
    @discardableResult
    func claimCurrentContents() -> Bool {
        let currentContents = PasteboardContents(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard currentContents.write(
            to: pasteboard,
            markerType: Self.markerType,
            markerData: markerData
        ) else {
            ownedChangeCount = nil
            return false
        }
        ownedChangeCount = pasteboard.changeCount
        return true
    }

    func restoreIfOwned() {
        guard let ownedChangeCount,
              pasteboard.changeCount == ownedChangeCount,
              pasteboard.pasteboardItems?.first?.data(forType: Self.markerType)
                == markerData else {
            return
        }
        originalContents.replaceContents(of: pasteboard)
        self.ownedChangeCount = nil
    }
}

private struct PasteboardContents {
    private let itemContents: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        itemContents = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        } ?? []
    }

    @discardableResult
    func write(
        to pasteboard: NSPasteboard,
        markerType: NSPasteboard.PasteboardType? = nil,
        markerData: Data? = nil
    ) -> Bool {
        var contents = itemContents
        if let markerType, let markerData {
            if contents.isEmpty {
                contents = [[markerType: markerData]]
            } else {
                contents[0][markerType] = markerData
            }
        }
        guard !contents.isEmpty else { return true }

        let items = contents.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }

    func replaceContents(of pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        _ = write(to: pasteboard)
    }
}
