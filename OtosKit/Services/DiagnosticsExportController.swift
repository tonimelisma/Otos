import AppKit
import Foundation

/// Diagnostics export controller guide
///
/// Help ▸ Export Diagnostics… is one intent, `chooseFolderAndExport()`: it asks for a folder
/// (an open panel that can make one) and queues an export into it. Exports run one at a time
/// in the order asked, in one consumer of one stream (ADR 0032, rule 5), and the blocking
/// write leaves the main actor in a detached task (rule 6). A written export is shown in
/// Finder, selected; one that could not be written is reported in an alert titled
/// `Couldn’t Export Diagnostics` with why (DES-037). Nothing else is shown.
///
/// The consumer holds no reference to the controller: it needs only the sources, and the
/// stream ends when the controller goes, which ends the loop.
@MainActor
final class DiagnosticsExportController {
    private let requests: AsyncStream<URL>.Continuation
    private let consumer: Task<Void, Never>

    init(sources: DiagnosticsExport.Sources) {
        let (stream, continuation) = AsyncStream<URL>.makeStream(bufferingPolicy: .unbounded)
        requests = continuation
        consumer = Task {
            for await folder in stream {
                let outcome = await Task.detached(priority: .userInitiated) {
                    DiagnosticsExport(sources: sources).write(into: folder, now: .now)
                }.value
                Self.present(outcome)
            }
        }
    }

    deinit {
        requests.finish()
        consumer.cancel()
    }

    /// Help ▸ Export Diagnostics…
    func chooseFolderAndExport() {
        let panel = NSOpenPanel()
        panel.title = "Export Diagnostics"
        panel.message = "Otos writes a new folder of its logs, crash reports and storage sizes here."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [requests] response in
            guard response == .OK, let folder = panel.url else { return }
            OtosLog.ui.noticeOperation("diagnostics.export", phase: "requested", fields: [
                "folder": folder.path(percentEncoded: false),
            ])
            requests.yield(folder)
        }
    }

    private static func present(_ outcome: DiagnosticsExport.Outcome) {
        switch outcome {
        case let .written(folder):
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        case let .failed(reason):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Export Diagnostics"
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        }
    }
}
