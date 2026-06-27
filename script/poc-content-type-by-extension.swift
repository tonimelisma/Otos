#!/usr/bin/env swift
//
// POC: enumerate a library root and report UTType identifiers grouped by extension.
// Mirrors CatalogScanner resource keys (metadata only, no byte reads).
//
// Usage:
//   swift script/poc-content-type-by-extension.swift [rootPath]
//
// Default root: ~/Desktop/OneDrive/Pictures
// (symlink to ~/Library/CloudStorage/OneDrive-Personal/Pictures)

import Foundation
import UniformTypeIdentifiers

struct ExtensionStats {
    var fileCount = 0
    var nilContentTypeCount = 0
    var utTypeCounts: [String: Int] = [:]
    var includeCount = 0
    var excludeCount = 0
}

let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Desktop/OneDrive/Pictures", isDirectory: true)

let rootURL: URL = if CommandLine.arguments.count > 1 {
    URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
} else {
    defaultRoot
}

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fputs("error: not a directory: \(rootURL.path)\n", stderr)
    exit(1)
}

// Preflight read access — CloudStorage needs Full Disk Access for CLI tools.
do {
    _ = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
} catch {
    fputs(
        """
        error: cannot read \(rootURL.path)
        \(error)
        Grant Full Disk Access to Terminal/Cursor if this is a CloudStorage path.

        """,
        stderr
    )
    exit(1)
}

let resourceKeys: Set<URLResourceKey> = [
    .isRegularFileKey,
    .isSymbolicLinkKey,
    .isPackageKey,
    .contentTypeKey,
]

func isCatalogMedia(_ identifier: String?) -> Bool {
    guard let identifier, let contentType = UTType(identifier) else { return false }
    return contentType.conforms(to: .image) || contentType.conforms(to: .movie)
}

var byExtension: [String: ExtensionStats] = [:]
var totalRegularFiles = 0
var skippedNonRegular = 0
var totalInclude = 0
var totalExclude = 0

guard let enumerator = FileManager.default.enumerator(
    at: rootURL,
    includingPropertiesForKeys: Array(resourceKeys),
    options: [.skipsPackageDescendants],
    errorHandler: { url, error in
        fputs("enumeration issue \(url.path): \(error)\n", stderr)
        return true
    }
) else {
    fputs("error: could not enumerate \(rootURL.path)\n", stderr)
    exit(1)
}

let clock = ContinuousClock()
let start = clock.now

while let fileURL = enumerator.nextObject() as? URL {
    do {
        let values = try fileURL.resourceValues(forKeys: resourceKeys)
        if values.isSymbolicLink == true || values.isPackage == true {
            continue
        }
        guard values.isRegularFile == true else {
            skippedNonRegular += 1
            continue
        }
        totalRegularFiles += 1

        let ext = fileURL.pathExtension.lowercased()
        let key = ext.isEmpty ? "(no extension)" : ext
        var stats = byExtension[key, default: ExtensionStats()]
        stats.fileCount += 1

        if let contentType = values.contentType {
            stats.utTypeCounts[contentType.identifier, default: 0] += 1
        } else {
            stats.nilContentTypeCount += 1
        }

        if isCatalogMedia(values.contentType?.identifier) {
            stats.includeCount += 1
            totalInclude += 1
        } else {
            stats.excludeCount += 1
            totalExclude += 1
        }
        byExtension[key] = stats
    } catch {
        fputs("resource issue \(fileURL.path): \(error)\n", stderr)
    }
}

let elapsed = start.duration(to: clock.now)

func padded(_ text: String, width: Int) -> String {
    if text.count >= width { return text }
    return text + String(repeating: " ", count: width - text.count)
}

print("Content type by extension POC")
print("Root: \(rootURL.path)")
print("Regular files: \(totalRegularFiles) (skipped non-regular: \(skippedNonRegular))")
print("Elapsed: \(elapsed)")
print()
print("\(padded("Extension", width: 18)) \(padded("Files", width: 8))  \(padded("Scan filter", width: 12))  UTTypes")
print(String(repeating: "-", count: 110))

for ext in byExtension.keys.sorted() {
    let stats = byExtension[ext]!
    let types = stats.utTypeCounts.sorted { $0.value > $1.value }
    let typeSummary = types.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
    let nilNote = stats.nilContentTypeCount > 0 && !typeSummary.isEmpty
        ? ", nil (\(stats.nilContentTypeCount))"
        : ""
    let displayTypes: String = if typeSummary.isEmpty {
        "nil (\(stats.nilContentTypeCount))"
    } else {
        typeSummary + nilNote
    }
    let filterLabel = if stats.includeCount == stats.fileCount {
        "include all"
    } else if stats.excludeCount == stats.fileCount {
        "exclude all"
    } else {
        "+\(stats.includeCount)/-\(stats.excludeCount)"
    }
    print("\(padded(ext, width: 18)) \(padded("\(stats.fileCount)", width: 8))  \(padded(filterLabel, width: 12))  \(displayTypes)")
}

print()
print("Planned scan filter (UTType conforms to image|movie; nil excluded):")
print("  would include: \(totalInclude)")
print("  would exclude: \(totalExclude)")
