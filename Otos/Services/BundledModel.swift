import Foundation

/// Bundled model guide (ADR 0044 §11)
///
/// Core ML compiles a model on its first load into the process's Caches and keys that copy
/// by the model's path exactly as given: the same bytes at a second path compile again, and
/// a symlink is a path of its own. The installed app holds each model at one path. Script
/// builds replace each built model with a symlink to a copy named by its content
/// (`otos_share_built_models`), so every checkout's tests load one path per model version;
/// resolving the link here is what makes that the path Core ML keys on.
nonisolated enum BundledModel {
    /// The compiled model `name` in `bundle`, its symlinks resolved; nil when the bundle
    /// holds no such model.
    static func url(named name: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "mlmodelc")?.resolvingSymlinksInPath()
    }
}
