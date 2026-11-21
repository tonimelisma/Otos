import Darwin
import Foundation

/// File bytes guide
///
/// **The one home for reading a file's bytes in bulk.** Every byte goes through `read(2)` into
/// one `ScratchBuffer`, so a read makes no allocation per chunk and leaves nothing in the
/// footprint after it ends (`ScratchBuffer`'s rule).
///
/// Why not Foundation: `FileHandle.read(upToCount:)` returns an autoreleased `NSData` for every
/// chunk. A synchronous loop runs inside one Swift-concurrency job, and that job's autorelease
/// pool drains only when the job ends, so each chunk stays alive until the last one is read.
/// Hashing a 400 MB file took the process from 1 MB to 403 MB of footprint, and it stayed at
/// 403 MB after the read: freed malloc blocks of that size are never returned on macOS 27
/// (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). `Data(contentsOf:)`
/// mallocs the whole file, which stays in the footprint the same way when it is freed
/// (`docs/research/2026-11-16-autoreleased-chunks-in-the-footprint.md`).
///
/// - `forEachChunk` streams a file through one reused buffer (the content hash, ADR 0018).
/// - `whole` reads a file into a mapped region. The returned `Data` owns that region, and the
///   region is unmapped when the last copy of the `Data` goes (a still's original, which the
///   renderer decodes from memory).
///
/// The caller has already checked that the bytes are local. Reading a dataless file here blocks
/// on its download, exactly as any read would.
nonisolated enum FileBytes {
    enum ReadError: Error, Equatable {
        case open(errno: Int32)
        case read(errno: Int32)
        case stat(errno: Int32)
        /// The file was shorter than its size when it was opened.
        case truncated
    }

    /// The default chunk for streaming reads: sequential and large enough that the system
    /// call costs nothing next to the copy.
    static let chunkSize = 1024 * 1024

    /// Calls `body` with each chunk of the file in order, every chunk in the same buffer; a
    /// chunk is valid only during its call. Returns false when `shouldContinue` stopped the
    /// read before the end.
    static func forEachChunk(
        of url: URL,
        chunkSize: Int = FileBytes.chunkSize,
        shouldContinue: () -> Bool = { true },
        _ body: (UnsafeRawBufferPointer) -> Void
    ) throws(ReadError) -> Bool {
        let descriptor = try open(url)
        defer { close(descriptor) }
        let buffer = ScratchBuffer<UInt8>(count: chunkSize)
        while true {
            guard shouldContinue() else {
                return false
            }
            let count = try readSome(descriptor, into: UnsafeMutableRawPointer(buffer.base), count: chunkSize)
            guard count > 0 else {
                return true
            }
            body(UnsafeRawBufferPointer(start: buffer.base, count: count))
        }
    }

    /// The whole file, in a mapped region the returned `Data` owns.
    static func whole(_ url: URL) throws(ReadError) -> Data {
        let descriptor = try open(url)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw .stat(errno: errno)
        }
        let size = Int(status.st_size)
        guard size > 0 else {
            return Data()
        }
        let buffer = ScratchBuffer<UInt8>(count: size)
        var filled = 0
        while filled < size {
            let count = try readSome(descriptor, into: UnsafeMutableRawPointer(buffer.base + filled), count: size - filled)
            guard count > 0 else {
                throw .truncated
            }
            filled += count
        }
        // The deallocator holds the buffer: the region lives exactly as long as the bytes.
        return Data(bytesNoCopy: buffer.base, count: size, deallocator: .custom { _, _ in
            withExtendedLifetime(buffer) {}
        })
    }

    private static func open(_ url: URL) throws(ReadError) -> Int32 {
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw .open(errno: errno)
        }
        return descriptor
    }

    /// One `read(2)`, retried when a signal interrupts it; 0 at the end of the file.
    private static func readSome(_ descriptor: Int32, into base: UnsafeMutableRawPointer, count: Int) throws(ReadError) -> Int {
        while true {
            let result = Darwin.read(descriptor, base, count)
            if result >= 0 {
                return result
            }
            if errno != EINTR {
                throw .read(errno: errno)
            }
        }
    }
}
