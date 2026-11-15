import CoreGraphics
import Foundation
import FoundationModels

/// Photo describer guide (ADR 0053)
///
/// The one call to Apple's on-device language model (`SystemLanguageModel.default`, Foundation
/// Models) that writes a still's description: the picture and its facts in one prompt, a typed
/// answer back (`GeneratedPhotoDescription`). Each request is its own session, so no photo's
/// answer is read with another's in context. The model runs on the Mac, offline, and costs the
/// user nothing; Private Cloud Compute is not used.
///
/// What a request comes to is classified by the framework's typed errors, never by their text:
/// the model's guardrails or a refusal are a verdict on these facts (`declined`); a model that
/// is not available — Apple Intelligence off, the Mac not eligible, the model not downloaded —
/// is `modelUnavailable`, so the writer stops until it may try again; anything else is a failed
/// request that writes nothing.
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
        let session = LanguageModelSession(model: model, instructions: PhotoDescriptionPrompt.instructions)
        do {
            let response = try await session.respond(generating: GeneratedPhotoDescription.self) {
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

    /// Whether `error` says the model is rate-limited or answering another request: the
    /// request may succeed later, and no request should be made before then.
    static func isBusy(_ error: any Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited, .concurrentRequests: return true
            default: return false
            }
        }
        if let error = error as? LanguageModelError, case .rateLimited = error {
            return true
        }
        return false
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
    @Guide(description: "Two or three lively, playful sentences about the photo.")
    var description: String
}

/// Writes a still's description: the live model in the app, a fake in tests.
typealias PhotoDescribing = @Sendable (CGImage, PhotoDescriptionPrompt) async throws -> PhotoDescriber.Outcome
