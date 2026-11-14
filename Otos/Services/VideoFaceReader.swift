import AVFoundation
import CoreGraphics
import Foundation

/// Video face reader guide (ADR 0047)
///
/// Reads a library video's faces from six of its frames, at fixed fractions of its length
/// (`samples`), decoded upright at full resolution with no tolerance, so a re-read finds the
/// same frames. Each frame goes through `FaceAnalyzer`, the same analysis a still's preview
/// gets. Measured on the owner's videos (`docs/research/2026-11-13-faces-in-video-frames.md`):
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
    /// decoder for them, or it has no image at a sampled time. Each is the platform's answer
    /// to the bytes it was given, and every read of them gives it again (measured on the
    /// owner's library: 67 videos each answered the same code on every read, up to 33 reads
    /// in three days, `docs/research/2026-11-14-videos-avfoundation-cannot-decode.md`).
    /// Classified by domain and code only. Anything else — an unknown error, a failed decode,
    /// which the same file has answered once and then read cleanly, a failed analysis — is
    /// not a verdict: the read failed, and the video's faces stay owed.
    static func isUndecodable(_ error: any Error) -> Bool {
        guard let error = error as? AVError else { return false }
        switch error.code {
        case .fileFormatNotRecognized, .fileFailedToParse, .failedToParse, .decoderNotFound, .noImageAtTime:
            return true
        default:
            return false
        }
    }

    /// A video's faces, one per person, with their frames staged under `finalRelativeName`.
    /// No faces when the video has no video track. Throws when a frame could not be read or
    /// analysed, so nothing is stamped and the video is read again.
    static func read(
        _ asset: AVURLAsset,
        analyzeFaces: FaceAnalysisReader,
        framesRelativeName: String,
        in directory: URL
    ) async throws -> EnrichedVideoFaces {
        let frames = try await Self.frames(of: asset)
        var faces: [[DetectedFace]] = []
        for frame in frames {
            try await faces.append(analyzeFaces(frame).faces)
        }
        let kept = onePerPerson(faces)
        guard !kept.isEmpty else {
            return .noneFound
        }
        let keptFrames = Array(Set(kept.map(\.frame))).sorted()
        let staged = try ThumbnailStore.stageFaceFrames(
            keptFrames.map { frames[$0] }, finalRelativeName: framesRelativeName, in: directory
        )
        return EnrichedVideoFaces(
            faces: kept.map { pick in
                EnrichedVideoFaces.Face(face: faces[pick.frame][pick.face], frameIndex: keptFrames.firstIndex(of: pick.frame)!)
            },
            analysisRevision: FaceAnalyzer.revision,
            frames: staged
        )
    }

    /// The frames at `samples`, in order; none for a video with no video track. Throws, and
    /// logs, when the duration or any frame cannot be read: an unread frame is not a frame
    /// without faces (ADR 0032), so a partial read is never stamped.
    @concurrent
    static func frames(of asset: AVURLAsset) async throws -> [CGImage] {
        do {
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [] }
            let duration = try await asset.load(.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var frames: [CGImage] = []
            for fraction in samples {
                try await frames.append(generator.image(at: CMTimeMultiplyByFloat64(duration, multiplier: fraction)).image)
            }
            return frames
        } catch {
            OtosLog.mediaIO.errorOperation("videoFaces.frames", phase: "unreadable", fields: [
                "path": asset.url.lastPathComponent, "error": String(describing: error),
            ])
            throw error
        }
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
