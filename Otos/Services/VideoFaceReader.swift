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

    /// A video's faces, one per person, with their frames staged under `finalRelativeName`.
    /// No faces when the video has no frame to read. Throws when the analysis failed, so
    /// nothing is stamped and the video is read again.
    static func read(
        _ asset: AVURLAsset,
        analyzeFaces: FaceAnalysisReader,
        framesRelativeName: String,
        in directory: URL
    ) async throws -> EnrichedVideoFaces {
        let frames = await Self.frames(of: asset)
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

    /// The frames at `samples` that decode, in order. A video with no video track, or whose
    /// frames do not decode, has none; each failure is logged.
    @concurrent
    static func frames(of asset: AVURLAsset) async -> [CGImage] {
        let name = asset.url.lastPathComponent
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            OtosLog.mediaIO.errorOperation("videoFaces.frames", phase: "durationUnreadable", fields: [
                "path": name, "error": String(describing: error),
            ])
            return []
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [CGImage] = []
        for fraction in samples {
            let time = CMTimeMultiplyByFloat64(duration, multiplier: fraction)
            do {
                try await frames.append(generator.image(at: time).image)
            } catch {
                OtosLog.mediaIO.errorOperation("videoFaces.frames", phase: "frameUnreadable", fields: [
                    "path": name, "fraction": "\(fraction)", "error": String(describing: error),
                ])
            }
        }
        return frames
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
