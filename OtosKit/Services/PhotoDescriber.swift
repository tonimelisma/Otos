import CoreGraphics
import Foundation
import FoundationModels

/// Photo describer guide (ADR 0053)
///
/// The one call to Apple's on-device language model (`SystemLanguageModel.default`, Foundation
/// Models) that writes a still's description: the photo's own instructions, then the picture and
/// its facts in one prompt, a typed
/// answer back (`GeneratedPhotoDescription`). Each request is its own session, so no photo's
/// answer is read with another's in context. The model runs on the Mac, offline, and costs the
/// user nothing; Private Cloud Compute is not used.
///
/// What a request comes to is classified by the framework's typed errors, never by their text:
/// the model's guardrails or a refusal are a verdict on these facts (`declined`). A request that
/// fails is classified by whom it is about (`Failure`): only an error the framework attributes
/// to this request — its context too large, its answer undecodable, its time run out — is about
/// the photo; a rate limit or a concurrent request is the model being busy; everything else is
/// the model, which can answer no request now — Apple Intelligence off, the Mac not eligible,
/// the model not downloaded, a capability it lacks, or a failure in its service that no public
/// case names (on the owner's Mac, 2026-11-20, a `ModelManagerError` 1026 relayed from an asset
/// lock the system could not take). A model failure holds every request, so a failure that is
/// not about the photo is never retried photo by photo across the library.
nonisolated enum PhotoDescriber {
    /// What the model wrote.
    enum Outcome: Equatable, Sendable {
        case written(String)
        /// The model declined to describe this photo with these facts.
        case declined
    }

    /// No request can be made: the model is not available on this Mac now.
    struct ModelUnavailable: Error, Sendable {
        let reason: String
    }

    /// Describes `image` with `prompt` through the system model.
    static func live(_ image: CGImage, _ prompt: PhotoDescriptionPrompt) async throws -> Outcome {
        let model = SystemLanguageModel.default
        if case let .unavailable(reason) = model.availability {
            throw ModelUnavailable(reason: String(describing: reason))
        }
        let session = LanguageModelSession(model: model, instructions: prompt.instructions)
        do {
            // Greedy sampling: the most likely words, the same answer for the same photo and
            // facts, and no sampled embellishment.
            let response = try await session.respond(
                generating: GeneratedPhotoDescription.self,
                options: GenerationOptions(sampling: .greedy)
            ) {
                prompt.facts
                Attachment(image)
            }
            let text = response.content.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .declined : .written(text)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                return .declined
            case .assetsUnavailable:
                throw ModelUnavailable(reason: "assetsUnavailable")
            default:
                throw error
            }
        } catch let error as LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal:
                return .declined
            default:
                throw error
            }
        }
    }

    /// Whom a failed request is about, read from the framework's typed errors.
    enum Failure: Equatable, Sendable {
        /// The request failed over this photo and its facts: another photo may be answered.
        case photo
        /// The model can answer no request now: not available, lacking a capability every
        /// request needs, or failing in its service.
        case model
        /// The model is rate-limited or answering another request.
        case busy

        init(_ error: any Error) {
            if let error = error as? LanguageModelSession.GenerationError {
                switch error {
                case .rateLimited, .concurrentRequests: self = .busy
                case .exceededContextWindowSize, .decodingFailure, .guardrailViolation, .refusal: self = .photo
                case .assetsUnavailable, .unsupportedGuide, .unsupportedLanguageOrLocale: self = .model
                @unknown default: self = .model
                }
            } else if let error = error as? LanguageModelError {
                switch error {
                case .rateLimited: self = .busy
                case .contextSizeExceeded, .timeout, .guardrailViolation, .refusal: self = .photo
                case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide,
                     .unsupportedLanguageOrLocale: self = .model
                @unknown default: self = .model
                }
            } else {
                // `ModelUnavailable`, and an error no public case names: the framework does not
                // attribute it to the request, so it is the model's.
                self = .model
            }
        }
    }

    /// The domain and code of `error` and of each error under it, outermost first
    /// (`FoundationModels.LanguageModelError:-1,ModelManagerServices.ModelManagerError:1026`):
    /// what a failure's log line names it by.
    static func causes(of error: any Error) -> String {
        var causes: [String] = []
        var pending: [NSError] = [error as NSError]
        while !pending.isEmpty {
            let next = pending.removeFirst()
            causes.append("\(next.domain):\(next.code)")
            pending += next.underlyingErrors.map { $0 as NSError }
        }
        return causes.joined(separator: ",")
    }

    /// Whether the system model can take a request now, as the Info pane says it.
    static var liveAvailability: PhotoDescriptionAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case let .unavailable(reason):
            switch reason {
            case .appleIntelligenceNotEnabled: .appleIntelligenceOff
            case .deviceNotEligible: .notEligible
            default: .notReady
            }
        }
    }
}

/// Whether descriptions can be written on this Mac: what the Info pane says for a still still
/// owed one.
nonisolated enum PhotoDescriptionAvailability: Equatable, Sendable {
    case available
    /// Apple Intelligence is turned off in System Settings.
    case appleIntelligenceOff
    /// This Mac cannot run Apple Intelligence.
    case notEligible
    /// The model is still downloading or the system is not ready.
    case notReady
}

/// The model's typed answer for one photo.
@Generable
nonisolated struct GeneratedPhotoDescription {
    @Guide(description: "One short, plain, matter-of-fact sentence saying what the photo shows.")
    var description: String
}

/// Writes a still's description: the live model in the app, a fake in tests.
typealias PhotoDescribing = @Sendable (CGImage, PhotoDescriptionPrompt) async throws -> PhotoDescriber.Outcome
