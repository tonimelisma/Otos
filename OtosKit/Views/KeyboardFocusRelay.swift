import AppKit
import SwiftUI

/// Keyboard focus relay guide
///
/// Edit ▸ Cut, Copy, Paste and Select All act on text whenever text holds the keyboard, and
/// otherwise Copy and Select All act on photos (DES-093). Whether text holds it is a fact
/// AppKit keeps: the key window's first responder. While any text field is being edited — an
/// edit value, the toolbar search field, People or Places search, a person's name, the
/// Immich sign-in, the export sheet's Long Edge — its window's first responder is the field
/// editor, an `NSText`; a selectable or editable text view is one too. Nothing keeps a list
/// of the fields that type text.
///
/// A command asks AppKit when it runs (`KeyboardFocus.live`), so what it acts on is never a
/// stale record. The relay keeps the record SwiftUI's menu needs to enable Cut and Paste
/// (`CatalogWindowViewModel.keyboardFocus`): it follows the key window
/// (`didBecomeKey`/`didResignKey`, and the app becoming or ceasing to be active;
/// `NSApplication.keyWindow` is not documented as key-value observable) and that window's
/// `firstResponder`, which is. Every report arrives on the main thread and is handed to the
/// window's one intent (`setKeyboardFocus`). The relay draws nothing and takes no click.
/// Which window holds the keyboard decides nothing: the key window's identity is not a record
/// that can be kept reliably across activation, popovers and sheets
/// (`docs/research/2026-11-26-copy-paste-and-cloud-originals.md`).
nonisolated enum KeyboardFocus: Equatable, Sendable {
    /// No text holds the keyboard: Copy and Select All act on photos.
    case photos
    /// Text holds the key window's keyboard: the Edit menu's text commands act on it.
    case text

    static func of(firstResponderIsText: Bool) -> KeyboardFocus {
        firstResponderIsText ? .text : .photos
    }

    /// What holds the keyboard now, as AppKit says it.
    @MainActor
    static var live: KeyboardFocus {
        of(firstResponderIsText: NSApp.keyWindow?.firstResponder is NSText)
    }

    /// The name the log gives it.
    var diagnosticName: String {
        switch self {
        case .photos: "photos"
        case .text: "text"
        }
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
            keyObservations = [
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            ].map { name in
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
            let focus = KeyboardFocus.of(firstResponderIsText: key?.firstResponder is NSText)
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
    }
}
