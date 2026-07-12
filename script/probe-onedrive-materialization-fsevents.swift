#!/usr/bin/env swift
import CoreServices
import Foundation

/// Bounded OneDrive materialization/FSEvents probe for plan 0056.
/// Run from an authorized Terminal: `swift script/probe-onedrive-materialization-fsevents.swift`
/// Does not modify catalog state. Materializes a few dataless samples only.

struct ProbeSample {
    let label: String
    let path: String
}

let root = NSString(
    string: "~/Library/CloudStorage/OneDrive-Personal/Pictures/Camera Roll"
).expandingTildeInPath

let samples: [ProbeSample] = [
    .init(label: "small-heic", path: "\(root)/2026/03/20260301_223622988_iOS.heic"),
    .init(label: "medium-heic", path: "\(root)/2026/03/20260301_223626227_iOS.heic"),
    .init(label: "small-mp4", path: "\(root)/2026/03/20260301_012533.mp4"),
]

let datalessFlag: UInt32 = 0x4000_0000

func flagsOf(_ path: String) -> (dataless: Bool, size: Int64, mtime: TimeInterval)? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return (
        dataless: (info.st_flags & datalessFlag) != 0,
        size: Int64(info.st_size),
        mtime: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    )
}

func decodeFlags(_ raw: UInt32) -> [String] {
    var names: [String] = []
    func add(_ name: String, _ flag: Int) {
        if raw & UInt32(flag) != 0 { names.append(name) }
    }
    add("mustScanSubDirs", kFSEventStreamEventFlagMustScanSubDirs)
    add("kernelDropped", kFSEventStreamEventFlagKernelDropped)
    add("userDropped", kFSEventStreamEventFlagUserDropped)
    add("itemCreated", kFSEventStreamEventFlagItemCreated)
    add("itemRemoved", kFSEventStreamEventFlagItemRemoved)
    add("itemInodeMetaMod", kFSEventStreamEventFlagItemInodeMetaMod)
    add("itemRenamed", kFSEventStreamEventFlagItemRenamed)
    add("itemModified", kFSEventStreamEventFlagItemModified)
    add("itemFinderInfoMod", kFSEventStreamEventFlagItemFinderInfoMod)
    add("itemChangeOwner", kFSEventStreamEventFlagItemChangeOwner)
    add("itemXattrMod", kFSEventStreamEventFlagItemXattrMod)
    add("itemIsFile", kFSEventStreamEventFlagItemIsFile)
    add("itemIsDir", kFSEventStreamEventFlagItemIsDir)
    add("itemIsSymlink", kFSEventStreamEventFlagItemIsSymlink)
    add("ownEvent", kFSEventStreamEventFlagOwnEvent)
    add("rootChanged", kFSEventStreamEventFlagRootChanged)
    if names.isEmpty { names.append(raw == 0 ? "none" : String(format: "unknown(0x%x)", raw)) }
    return names
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(t: TimeInterval, path: String, flags: UInt32)] = []
    let started = Date()

    func append(path: String, flags: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        events.append((Date().timeIntervalSince(started), path, flags))
    }

    func snapshot() -> [(t: TimeInterval, path: String, flags: UInt32)] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

let collector = EventCollector()
let paths = [root] as CFArray
var context = FSEventStreamContext(
    version: 0,
    info: Unmanaged.passUnretained(collector).toOpaque(),
    retain: nil,
    release: nil,
    copyDescription: nil
)

let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
    guard let info, count > 0 else { return }
    let collector = Unmanaged<EventCollector>.fromOpaque(info).takeUnretainedValue()
    let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    for index in 0 ..< count {
        guard let path = array[index] as? String else { continue }
        collector.append(path: path, flags: eventFlags[index])
    }
}

guard let stream = FSEventStreamCreate(
    kCFAllocatorDefault,
    callback,
    &context,
    paths,
    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
    0.05,
    FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagIgnoreSelf
    )
) else {
    fputs("stream create failed\n", stderr)
    exit(1)
}

let queue = DispatchQueue(label: "probe.fsevents")
FSEventStreamSetDispatchQueue(stream, queue)
FSEventStreamStart(stream)
Thread.sleep(forTimeInterval: 0.3)

print("probe root=\(root)")
for sample in samples {
    guard let before = flagsOf(sample.path) else {
        print("SKIP \(sample.label) missing path=\(sample.path)")
        continue
    }
    print(
        "BEFORE label=\(sample.label) dataless=\(before.dataless) size=\(before.size) mtime=\(before.mtime) path=\(sample.path)"
    )
    guard before.dataless else {
        print("SKIP \(sample.label) already materialized")
        continue
    }

    let url = URL(fileURLWithPath: sample.path)
    let requestStart = Date().timeIntervalSince(collector.started)
    do {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        print("REQUESTED label=\(sample.label) t=\(String(format: "%.3f", requestStart))")
    } catch {
        print("REQUEST_FAIL label=\(sample.label) error=\(error)")
        continue
    }

    let deadline = Date().addingTimeInterval(90)
    var after = before
    while Date() < deadline {
        if let current = flagsOf(sample.path), !current.dataless {
            after = current
            break
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let doneAt = Date().timeIntervalSince(collector.started)
    print(
        "AFTER label=\(sample.label) t=\(String(format: "%.3f", doneAt)) dataless=\(after.dataless) size=\(after.size) mtime=\(after.mtime) sizeChanged=\(after.size != before.size) mtimeChanged=\(after.mtime != before.mtime)"
    )

    let relevant = collector.snapshot().filter { event in
        event.path == sample.path || event.path.hasPrefix(sample.path)
            || sample.path.hasPrefix(event.path + "/")
    }
    for event in relevant {
        print(
            "EVENT label=\(sample.label) t=\(String(format: "%.3f", event.t)) flags=0x\(String(event.flags, radix: 16)) decoded=\(decodeFlags(event.flags).joined(separator: ",")) path=\(event.path)"
        )
    }
    if relevant.isEmpty {
        print("EVENT label=\(sample.label) none matching path within window")
    }
}

FSEventStreamStop(stream)
FSEventStreamInvalidate(stream)
FSEventStreamRelease(stream)
print("probe done")
