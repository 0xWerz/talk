import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional grammar and punctuation polish using Apple's on-device model.
///
/// This is the deliberate alternative to shipping our own LLM: the model is
/// managed by the OS and shared system-wide, so Talk adds no resident weights
/// of its own. It is off by default, strictly bounded, and any suspicious
/// result is discarded in favour of the rule-cleaned text.
@MainActor
final class Polisher {
    /// Give up rather than make the user wait; the rule-cleaned text is fine.
    private static let budget: Duration = .milliseconds(2500)
    /// Long dictations are not worth the latency, and drift risk grows.
    private static let maxCharacters = 1200

    private let instructions = """
        You are a proofreader for voice dictation. You receive a raw transcript \
        and return the same text with spelling, grammar, punctuation and \
        capitalization corrected.

        Rules you must never break:
        - Preserve the speaker's words, meaning, tone and ordering.
        - Never answer, explain, summarize, translate or continue the text.
        - Never add or remove sentences, and never add commentary or quotes.
        - If the text is already correct, return it unchanged.
        Output only the corrected text.
        """

    enum Availability {
        case ready
        case unsupported(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
        var explanation: String? {
            if case .unsupported(let reason) = self { return reason }
            return nil
        }
    }

    var availability: Availability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return .unsupported("Requires macOS 26 or later.")
        }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unsupported("Turn on Apple Intelligence in System Settings.")
        case .unavailable(.deviceNotEligible):
            return .unsupported("This Mac doesn't support Apple Intelligence.")
        case .unavailable(.modelNotReady):
            return .unsupported("The system model is still downloading.")
        case .unavailable(let other):
            return .unsupported("Unavailable: \(other).")
        }
        #else
        return .unsupported("Built without FoundationModels.")
        #endif
    }

    /// Returns polished text, or `nil` to mean "keep what you had".
    func polish(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), availability.isReady else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxCharacters else { return nil }

        let work = Task { () -> String? in
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: trimmed,
                options: GenerationOptions(temperature: 0.0)
            )
            return response.content
        }
        let timeout = Task {
            try? await Task.sleep(for: Self.budget)
            work.cancel()
        }
        defer { timeout.cancel() }

        do {
            guard let candidate = try await work.value else { return nil }
            return Self.accept(candidate, original: trimmed)
        } catch {
            Log.error("polish", "fell back to rule cleanup: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// A proofreader should return something the same size and shape. Anything
    /// else means the model started talking to us instead, so we drop it.
    static func accept(_ candidate: String, original: String) -> String? {
        var cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 1, cleaned.hasPrefix("\""), cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        guard !cleaned.isEmpty else { return nil }

        let ratio = Double(cleaned.count) / Double(max(original.count, 1))
        guard ratio > 0.6, ratio < 1.5 else { return nil }

        // Refusals and meta-commentary rather than a correction.
        let lowered = cleaned.lowercased()
        let tells = ["i can't", "i cannot", "as an ai", "here is the corrected",
                     "corrected text:", "sure,", "i'm unable"]
        if tells.contains(where: lowered.hasPrefix) { return nil }

        // The words should be largely the same ones the speaker said.
        let originalWords = Set(Self.words(in: original))
        let candidateWords = Self.words(in: cleaned)
        guard !candidateWords.isEmpty else { return nil }
        let kept = candidateWords.filter { originalWords.contains($0) }.count
        guard Double(kept) / Double(candidateWords.count) >= 0.65 else { return nil }

        return cleaned
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }
}
