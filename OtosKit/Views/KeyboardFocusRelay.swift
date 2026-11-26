import AppKit
import SwiftUI

/// Keyboard focus relay guide
///
/// Edit ▸ Cut, Copy, Paste and Select All act on text whenever text holds the keyboard, and
/// on photos only when the catalog window holds it (DES-093). Which one holds it is a fact
/// AppKit keeps: the key window's first responder. While any text field is being edited —
/// an edit value, the toolbar search field, People or Places search, a person's name, the
/// Immich sign-in, the export sheet's Long Edge — its window's first responder is the field
/// editor, an `NSText`; a selectable or editable text view is one too. So the relay reads
/// that one fact rather than keeping a list of the fields that type text, which a new field
/// or a field that leaves without reporting it (a panel hidden while its field is focused)
/// silently falsifies.
///
/// It follows the key window (`didBecomeKey`/`didResignKey`; `NSApplication.keyWindow` is
/// not documented as key-value observable) and that window's `firstResponder`, which is.
/// Both report on the main thread, and every report is classified at once and handed to
/// the window's one intent (`CatalogWindowViewModel.setKeyboardFocus`). The relay draws
/// nothing and takes no click; it joins the catalog window as a background view, which is
/// how it knows which window is the catalog's.
nonisolated enum KeyboardFocus: Equatable, Sendable {
    /// The catalog window is key and no text holds its keyboard: Copy and Select All act on
    /// photos.
    case photos
    /// Text holds the key window's keyboard: the Edit menu's text commands act on it.
    case text
    /// Another window is key — a sheet, Settings, an alert — with no text holding its
    /// keyboard, or no window is: nothing acts on photos behind it.
    case elsewhere

    /// The focus for a key window and its first responder: text wherever text holds it,
    /// photos only in the catalog window.
    static func of(keyWindowIsCatalog: Bool?, firstResponderIsText: Bool) -> KeyboardFocus {
        guard let keyWindowIsCatalog else { return .elsewhere }
        if firstResponderIsText {
            return .text
        }
        return keyWindowIsCatalog ? .photos : .elsewhere
    }
}

struct KeyboardFocusRelay: NSViewRepresentable {
    let report: (KeyboardFocus) -> Void

    func makeNSView(context _: Context) -> RelayView {
        let view = RelayView()
        view.report = report
        return view
    }

    func updateNSView(_ view: RelayView, context _: Context) {
        view.report = report
    }

    final class RelayView: NSView {
        var report: (KeyboardFocus) -> Void = { _ in }
        /// The window whose first responder is watched: the key window.
        private weak var watched: NSWindow?
        private var firstResponderObservation: NSKeyValueObservation?
        private var keyObservations: [any NSObjectProtocol] = []
        private var reported: KeyboardFocus?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            keyObservations.forEach { center.removeObserver($0) }
            keyObservations = []
            guard window != nil else {
                watch(nil)
                return
            }
            // Delivered on the main queue, which is the main actor's.
            keyObservations = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.update()
                    }
                }
            }
            update()
        }

        /// Reads the key window and its first responder and reports what holds the keyboard
        /// when that changed.
        private func update() {
            let key = NSApp.keyWindow
            if key !== watched {
                watch(key)
            }
            let focus = Self.focus(of: key, catalogWindow: window)
            guard focus != reported else { return }
            reported = focus
            report(focus)
        }

        private func watch(_ next: NSWindow?) {
            watched = next
            // AppKit changes a window's first responder on the main thread.
            firstResponderObservation = next?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.update()
                }
            }
        }

        /// What holds the keyboard of `key`, given the catalog window.
        static func focus(of key: NSWindow?, catalogWindow: NSWindow?) -> KeyboardFocus {
            KeyboardFocus.of(
                keyWindowIsCatalog: key.map { $0 === catalogWindow },
                firstResponderIsText: key?.firstResponder is NSText
            )
        }
    }
}
