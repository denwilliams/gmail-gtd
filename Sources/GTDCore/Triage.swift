import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct TriageSuggestion: Sendable {
    public var bucket: GTDBucket
    public var nextAction: String
    public var summary: String
    public var waitingOn: String?
}

public struct ProjectPlan: Sendable {
    public var summary: String
    public var steps: [String]
}

public enum TriageError: Error, LocalizedError {
    case modelUnavailable(String)
    public var errorDescription: String? {
        if case .modelUnavailable(let why) = self { return "On-device model unavailable: \(why)" }
        return nil
    }
}

#if canImport(FoundationModels)

@Generable
enum GeneratedBucket: String {
    case nextAction, waitingFor, someday, reference, project
}

@Generable
struct GeneratedTriage {
    @Guide(description: "The GTD bucket. nextAction: the user must do something soon. waitingFor: the user is waiting on someone else. someday: optional or low priority. reference: information to keep, no action. project: needs multiple steps.")
    var bucket: GeneratedBucket
    @Guide(description: "One concrete next physical action, starting with a verb, under 12 words. Empty for reference.")
    var nextAction: String
    @Guide(description: "One or two sentences summarising the thread.")
    var summary: String
    @Guide(description: "Who the user is waiting on, only for waitingFor. Otherwise empty.")
    var waitingOn: String
}

@Generable
struct GeneratedPlan {
    @Guide(description: "One or two sentences on what this project is.")
    var summary: String
    @Guide(description: "Two to five concrete steps, each starting with a verb, under 12 words.")
    var steps: [String]
}

/// On-device triage using Apple Foundation Models. Nothing leaves the Mac.
public struct Triager: Sendable {
    // The on-device model has a small context window, so threads are trimmed hard.
    private static let maxChars = 6000

    public init() {}

    public func suggest(for thread: GmailThread, me: String? = nil) async throws -> TriageSuggestion {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw TriageError.modelUnavailable(String(describing: model.availability))
        }
        let session = LanguageModelSession(instructions: """
            You triage email for someone using Getting Things Done. Be conservative: \
            only choose nextAction if the user themself must act.
            """)
        let result = try await session.respond(to: Self.prompt(for: thread), generating: GeneratedTriage.self)
        let t = result.content
        return TriageSuggestion(
            bucket: GTDBucket(rawValue: t.bucket.rawValue) ?? .reference,
            nextAction: t.nextAction, summary: t.summary,
            waitingOn: t.waitingOn.isEmpty ? nil : t.waitingOn)
    }

    /// Short digest of what needs attention, built from already-fetched subjects and snippets.
    public func digest(nextActions: [String], waitingFor: [String]) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw TriageError.modelUnavailable(String(describing: model.availability))
        }
        let session = LanguageModelSession(instructions: "You write a two-sentence morning briefing for someone using Getting Things Done. Plain, direct, no greeting.")
        let list = { (items: [String]) in items.prefix(12).map { "- \($0.prefix(120))" }.joined(separator: "\n") }
        let prompt = "Next actions:\n\(list(nextActions))\n\nWaiting for:\n\(list(waitingFor))\n\nBriefing:"
        return try await session.respond(to: prompt).content
    }

    /// Summary and concrete steps for a project thread.
    public func plan(for thread: GmailThread) async throws -> ProjectPlan {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw TriageError.modelUnavailable(String(describing: model.availability))
        }
        let session = LanguageModelSession(instructions: "You break email projects into concrete steps for someone using Getting Things Done.")
        let r = try await session.respond(to: Self.prompt(for: thread), generating: GeneratedPlan.self)
        return ProjectPlan(summary: r.content.summary, steps: r.content.steps)
    }

    static func prompt(for thread: GmailThread) -> String {
        // Newest messages first, quoted replies dropped, until the budget is spent.
        var budget = maxChars
        var chunks: [String] = []
        for m in (thread.messages ?? []).reversed() {
            let body = m.plainText.split(separator: "\n", omittingEmptySubsequences: true)
                .filter { !$0.hasPrefix(">") }.joined(separator: "\n")
            let chunk = "From: \(m.from)\nSubject: \(m.subject)\n\(body.prefix(max(0, min(budget, 2500))))"
            budget -= chunk.count
            chunks.append(chunk)
            if budget <= 0 { break }
        }
        return "Triage this email thread (newest message first):\n\n" + chunks.joined(separator: "\n---\n")
    }
}

#else

public struct Triager: Sendable {
    public init() {}
    public func suggest(for thread: GmailThread, me: String? = nil) async throws -> TriageSuggestion {
        throw TriageError.modelUnavailable("FoundationModels is not available on this platform")
    }
    public func digest(nextActions: [String], waitingFor: [String]) async throws -> String {
        throw TriageError.modelUnavailable("FoundationModels is not available on this platform")
    }
    public func plan(for thread: GmailThread) async throws -> ProjectPlan {
        throw TriageError.modelUnavailable("FoundationModels is not available on this platform")
    }
}

#endif
