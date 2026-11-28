import AVFoundation
import CoreGraphics
import Foundation

/// Video face reader guide (ADR 0047)
///
/// Reads a library video's faces from six of its frames, at fixed fractions of its length
/// (`samples`), decoded upright at full resolution with no tolerance, so a re-read finds the
/// same frames. Each frame goes through `FaceAnalyzer`, the same analysis a still's preview
/// gets. Measured on the reference library's videos (`docs/research/2026-11-13-faces-in-video-frames.md`):
/// these six frames find a face in every video where any frame of the measured set has one,
/// and the model names the same person in every frame of a video.
///
/// One person in a video is one face (`onePerPerson`): frames of the same person score 0.54
/// to 0.98 against each other there, and different people at most 0.17, so faces whose
/// likeness reaches assignment's threshold are one person, kept by their sharpest reading. Two
/// faces of one frame are never one person, and a face the model cannot tell anyone by
/// (`FaceRecognisability`) is never joined with another, as assignment never compares it.
///
/// The frames the kept faces were read in are staged as one HEIC of the preview's size, for
/// the face tiles to be cut from. Called by `MediaEnricher` on a library video whose bytes
/// are already local for the read, and on an Immich account's video read in byte ranges
/// from its server (`RemoteVideoAsset`); it never downloads an original.
nonisolated enum VideoFaceReader {
    /// Where a video's frames are read, as fractions of its duration.
    static let samples: [Double] = [0, 0.1, 0.25, 0.5, 0.75, 0.9]

    /// Otos's own part of the decoder: how it asks AVFoundation for a video's frames
    /// (`samples`, no tolerance, upright). A change to that which can make an undecodable
    /// video readable is a new revision.
    static let decodeRevision = 1

    /// The decoder a verdict of "cannot decode" about a video is about: Otos's revision and
    /// the macOS build, whose AVFoundation decodes the frames. A video it could not decode
    /// is read again once either changes (ENR-031).
    static let decoderIdentity = DecodeVerdict.decoder("otos-video", revision: decodeRevision)

    /// Whether `error`, thrown by `read`, is AVFoundation's word that it cannot decode this
    /// video's bytes: their format is not one it recognises, they do not parse, it has no
    /// decoder for them — said by its track before any frame is asked for
    /// (`VideoFaceReaderError.trackNotDecodable`), or by a frame's read — or it has no image
    /// at a sampled time. Each is the platform's answer
    /// to the bytes it was given, and every read of them gives it again (measured on the
    /// reference library: 67 videos each answered the same code on every read, up to 33 reads
    /// in three days, `docs/research/2026-11-14-videos-avfoundation-cannot-decode.md`).
    /// One `unknown` is a verdict too, by its underlying status: an AVI whose data stops
    /// before its header says it does (`truncatedAVIStatus`). Every truncation of an AVI
    /// tried answered it on every read, an intact AVI answered `decodeFailed`, and truncated
    /// MP4 and MOV files answered other codes; in the reference library's log only three truncated AVIs
    /// answered it (`docs/research/2026-11-14-derived-owners-and-face-checks.md`).
    /// Classified by domain and code only, and the underlying status's domain and code.
    /// Anything else — another unknown error (an outage once gave MKVs `unknown` over
    /// -17761), a failed decode, which the same file has answered once and then read
    /// cleanly, a failed analysis — is not a verdict: the read failed, and the video's faces
    /// stay owed.
    static func isUndecodable(_ error: any Error) -> Bool {
        if case VideoFaceReaderError.trackNotDecodable = error {
            return true
        }
        guard let error = error as? AVError else { return false }
        switch error.code {
        case .fileFormatNotRecognized, .fileFailedToParse, .failedToParse, .decoderNotFound, .noImageAtTime:
            return true
        case .unknown:
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            return underlying?.domain == NSOSStatusErrorDomain && underlying?.code == truncatedAVIStatus
        default:
            return false
        }
    }

    /// The status under AVFoundation's `unknown` for an AVI whose data is cut short.
    static let truncatedAVIStatus = -12344

    /// A video's faces, one per person, with their frames staged under `finalRelativeName`.
    /// No faces when the video has no video track. Throws `trackNotDecodable` before any
    /// frame is asked for when AVFoundation says its video track is not decodable on this Mac
    /// (a VP9 movie, with no VP9 decoder for it). Throws when the duration or a frame could
    /// not be read, or a frame not analysed: an unread frame is not a frame without faces
    /// (ADR 0032), so a partial read is never stamped and the video is read again.
    /// `atSyncFrame` hears each sample read at a sync frame instead (`frame(at:)`).
    /// `bytesUnanswered` says whether the asset's source failed to send bytes it was asked
    /// for (`RemoteVideoAsset.failed`): a frame that failed for want of its bytes is not one
    /// AVFoundation cannot seek to, so it has no sync-frame fallback and the read ends at it.
    /// The caller logs what the read came to, once, with the error.
    @concurrent
    static func read(
        _ asset: AVURLAsset,
        analyzeFaces: FaceAnalysisReader,
        framesRelativeName: String,
        in directory: URL,
        bytesUnanswered: @escaping @Sendable () -> Bool = { false },
        atSyncFrame: @escaping @Sendable (_ sample: Int) -> Void = { _ in }
    ) async throws -> EnrichedVideoFaces {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .noneFound }
        guard try await track.load(.isDecodable) else { throw VideoFaceReaderError.trackNotDecodable }
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await read(
            frame: { index in
                try await frame(
                    at: CMTimeMultiplyByFloat64(duration, multiplier: samples[index]),
                    decode: { try await generator.image(at: $0).image },
                    syncFrame: { bytesUnanswered() ? nil : syncFrameTime(near: $0, in: track) },
                    atSyncFrame: { atSyncFrame(index) }
                )
            },
            analyzeFaces: analyzeFaces, framesRelativeName: framesRelativeName, in: directory
        )
    }

    /// The frame at `time`, or, when AVFoundation fails to decode it (`decodeFailed`), the
    /// sync frame `syncFrame` names near it. AVFoundation decodes a frame by seeking to the
    /// sync frame before it and decoding forward; in some HEVC videos with open groups of
    /// pictures its seek fails on the few frames just before a sync frame every time they
    /// are asked for, though the same frames decode in order (measured on the reference library's
    /// account videos, `docs/research/2026-11-19-account-videos-unread-faces.md`). A sync
    /// frame needs no other frame, so a seek always reaches it, and it is the same frame on
    /// every read. A sampled frame that is itself a sync frame has no fallback: its failure
    /// is the decoder's, and it is thrown.
    static func frame(
        at time: CMTime,
        decode: (CMTime) async throws -> CGImage,
        syncFrame: (CMTime) -> CMTime?,
        atSyncFrame: () -> Void
    ) async throws -> CGImage {
        do {
            return try await decode(time)
        } catch let error as AVError where error.code == .decodeFailed {
            guard let sync = syncFrame(time) else { throw error }
            atSyncFrame()
            return try await decode(sync)
        }
    }

    /// The presentation time of the sync frame nearest after the frame shown at `time`, else
    /// the nearest before it; nil when that frame is itself a sync frame, or the track cannot
    /// say.
    static func syncFrameTime(near time: CMTime, in track: AVAssetTrack) -> CMTime? {
        guard track.canProvideSampleCursors,
              let sampled = track.makeSampleCursor(presentationTimeStamp: time),
              !sampled.currentSampleSyncInfo.sampleIsFullSync.boolValue
        else {
            return nil
        }
        for direction: Int64 in [1, -1] {
            guard let cursor = track.makeSampleCursor(presentationTimeStamp: time) else { return nil }
            while cursor.stepInPresentationOrder(byCount: direction) == direction {
                if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                    return cursor.presentationTimeStamp
                }
            }
        }
        return nil
    }

    /// The read over `frame`, which decodes the frame at `samples[index]`. One full-resolution
    /// frame is held at a time: each is analysed before the next is decoded, and one in which
    /// faces were found is kept only as it is staged, scaled to the preview's size
    /// (`ThumbnailStore.scaled`, which staging then leaves as it is). An iPhone's 4K HDR frame
    /// decodes to about 66 MB, and two videos read at once holding all six frames each added
    /// 890 MB (`docs/research/2026-11-16-first-launch-footprint.md`).
    static func read(
        frame: (Int) async throws -> CGImage,
        analyzeFaces: FaceAnalysisReader,
        framesRelativeName: String,
        in directory: URL
    ) async throws -> EnrichedVideoFaces {
        var faces: [[DetectedFace]] = []
        var shown: [Int: CGImage] = [:]
        for index in samples.indices {
            let decoded = try await frame(index)
            let found = try await analyzeFaces(decoded).faces
            faces.append(found)
            if !found.isEmpty {
                shown[index] = try ThumbnailStore.scaled(decoded, toLongEdge: ThumbnailStore.previewMaxPixelSize)
            }
        }
        let kept = onePerPerson(faces)
        guard !kept.isEmpty else {
            return .noneFound
        }
        let keptFrames = Array(Set(kept.map(\.frame))).sorted()
        let staged = try ThumbnailStore.stageFaceFrames(
            keptFrames.map { shown[$0]! }, finalRelativeName: framesRelativeName, in: directory
        )
        return EnrichedVideoFaces(
            faces: kept.map { pick in
                EnrichedVideoFaces.Face(face: faces[pick.frame][pick.face], frameIndex: keptFrames.firstIndex(of: pick.frame)!)
            },
            analysisRevision: FaceAnalyzer.revision,
            frames: staged
        )
    }

    /// One face per person across `frames`, each frame's faces in reading order: the face and
    /// frame each person is kept by, in frame order. Faces are taken sharpest first; each
    /// joins the person it is most like when that likeness reaches assignment's threshold and
    /// that person has no face in its frame, and is a person of its own otherwise. A face the
    /// model cannot tell anyone by is always a person of its own.
    static func onePerPerson(_ frames: [[DetectedFace]]) -> [(frame: Int, face: Int)] {
        struct Reading {
            let frame: Int
            let face: Int
            let embedding: FaceEmbedding
            let recognisable: Bool
        }
        let readings = frames.enumerated().flatMap { frame, faces in
            faces.enumerated().map { face, detected in
                (quality: detected.quality, reading: Reading(
                    frame: frame, face: face, embedding: detected.embedding,
                    recognisable: FaceRecognisability.isRecognisable(detected.embedding)
                ))
            }
        }
        .sorted { ($0.quality, -$0.reading.frame, -$0.reading.face) > ($1.quality, -$1.reading.frame, -$1.reading.face) }
        .map(\.reading)
        var people: [[Reading]] = []
        for reading in readings {
            var best: (person: Int, likeness: Float)?
            if reading.recognisable {
                for (index, person) in people.enumerated()
                    where person[0].recognisable && !person.contains(where: { $0.frame == reading.frame })
                {
                    let likeness = person.map { reading.embedding.cosine(with: $0.embedding) }.max()!
                    if likeness >= FaceAssignmentPolicy.threshold, likeness > best?.likeness ?? -.infinity {
                        best = (index, likeness)
                    }
                }
            }
            if let best {
                people[best.person].append(reading)
            } else {
                people.append([reading])
            }
        }
        return people.map { ($0[0].frame, $0[0].face) }.sorted { ($0.frame, $0.face) < ($1.frame, $1.face) }
    }
}

nonisolated enum VideoFaceReaderError: Error, Equatable {
    /// AVFoundation says the video's track is not decodable on this Mac
    /// (`AVAssetTrack.isDecodable`): it has no decoder for its codec.
    case trackNotDecodable
}
