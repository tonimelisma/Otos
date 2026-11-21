import AppKit
import Foundation

/// Share picker presenter guide
///
/// The one AppKit object that shows the system share picker for a list of file URLs.
/// `NSSharingServicePicker` must stay alive while its popover is on screen and wants an
/// `NSObject` delegate to learn when it closes; the ViewModel is neither, so this
/// small owner holds the picker from `show` until the delegate's `didChoose`. It
/// carries no state of its own beyond that reference and reads no bytes — the picker
/// receives URLs, and any preview or download is the system's act (ADR 0012).
@MainActor
final class SharePickerPresenter: NSObject, NSSharingServicePickerDelegate {
    private(set) var activePicker: NSSharingServicePicker?

    /// Presents the picker anchored to `rect` in `view`; a picker already showing is
    /// replaced, which is what a second Share… while one is open should do.
    func present(_ items: [URL], relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge = .minY) {
        guard !items.isEmpty else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        activePicker = picker
        picker.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    /// AppKit delivers this on the main thread; only the picker's identity crosses into
    /// the MainActor region, so the reference itself is never sent.
    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose _: NSSharingService?) {
        let finished = ObjectIdentifier(picker)
        MainActor.assumeIsolated {
            if let active = activePicker, ObjectIdentifier(active) == finished {
                activePicker = nil
            }
        }
    }
}
