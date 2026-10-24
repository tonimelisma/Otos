import Foundation
@testable import OtosKit

/// Trash file operations for tests. A test never reaches the user's system Trash: it
/// passes `.refusing`, a Trash of its own (`.folder`), or its own trash act (`.testing`).
extension MediaTrashCoordinator.FileOperations {
    /// The test's own trash act; deleting and putting back act on the test's own files.
    static func testing(
        trash: @escaping MediaTrashCoordinator.TrashExecutor,
        remove: @escaping MediaTrashCoordinator.RemoveExecutor = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) -> Self {
        Self(
            trash: trash,
            remove: remove,
            putBack: { from, to in
                try FileManager.default.moveItem(at: from, to: to)
            }
        )
    }

    /// A Trash that is a folder the test owns: files really move into it and back, and
    /// each keeps a unique name there, as in the system Trash.
    static func folder(_ trash: URL) -> Self {
        testing(trash: { url in
            let destination = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }
}
