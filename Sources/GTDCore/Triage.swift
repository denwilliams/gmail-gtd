import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct TriageSuggestion: Sendable, Codable {
    public var bucket: GTDBucket
    public var nextAction: String
    public var summary: String
    public var waitingOn: String?

    /// The first sentence: short enough for the list, and a complete thought on its own.
    public var headline: String { summary.firstSentence }
    /// The rest of the summary, for the detail view.
    public var details: String { String(summary.dropFirst(headline.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Maps the model's answers to a GTD bucket. Plain strings so it works, and is testable, without the model.
public enum TriageRules {
    public static func bucket(whoActs: String, kind: String, asksUser: Bool = true) -> GTDBucket {
        switch kind {
        case "noise": return .noise
        case "informationOnly": return .reference
        case "optionalIdea": return .someday
        case "multiStepProject": return .project
        default:
            if whoActs == "someoneElse" { return .waitingFor }
            // Nothing is being asked of the user, so there is nothing to act on.
            if whoActs == "nobody" || !asksUser { return .reference }
            return .nextAction
        }
    }
}

public struct ProjectPlan: Sendable, Codable {
    public var summary: String
    public var steps: [String]

    public var headline: String { summary.firstSentence }
    public var details: String { String(summary.dropFirst(headline.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
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
enum WhoActs: String {
    case user, someoneElse, nobody
}

@Generable
enum ThreadKind: String {
    case singleTask, multiStepProject, optionalIdea, informationOnly, noise
}

/// Small questions the on-device model answers reliably. The bucket itself is chosen in code (`TriageRules`).
@Generable
struct GeneratedTriage {
    /// Scratch space: thinking in a sentence or two first measurably improves the answers below. It is
    /// discarded; the summary people read comes from a separate request (`GeneratedSummary`).
    @Guide(description: "One or two sentences summarising the thread.")
    var summary: String
    @Guide(description: "True only if the last message directly asks, instructs or expects the user to do, decide, answer or approve something. False for announcements, notices, alerts, receipts, newsletters and updates.")
    var asksUser: Bool
    @Guide(description: "Who must act next. user: the user was asked to do, decide, review or reply to something. someoneElse: the user already asked someone else for something and is waiting on them. nobody: no action is needed, including notices that say nothing is required.")
    var whoActs: WhoActs
    @Guide(description: "What the thread is. singleTask: one concrete action. multiStepProject: needs several separate steps over time. optionalIdea: a nice-to-have or suggestion from a person with no deadline. informationOnly: a receipt, confirmation, document or notes worth keeping for later. noise: bulk marketing, promotions, newsletters, policy or terms updates, and automated alerts or notices that need nothing from the user and are not worth keeping.")
    var kind: ThreadKind
    @Guide(description: "One concrete next physical action for the user, starting with a verb, under 12 words. Empty if nobody needs to act.")
    var nextAction: String
    @Guide(description: "Name of the person the user is waiting on. Empty unless whoActs is someoneElse.")
    var waitingOn: String
}

/// The summary people read. Made by its own request so it can be long and fluent without nudging the
/// classification, which a small model otherwise lets its own wording steer.
@Generable
struct GeneratedSummary {
    @Guide(description: "A summary of three to five sentences. The first sentence must make sense on its own as a headline, under 20 words. The next sentences add the key details: who is involved, dates, amounts, and what is being asked or announced.")
    var summary: String
}

@Generable
struct GeneratedPlan {
    @Guide(description: "Three or four sentences on what this project is, its current state and what is outstanding. The first sentence must make sense on its own as a headline, under 20 words.")
    var summary: String
    @Guide(description: "Two to five concrete steps, each starting with a verb, under 12 words.")
    var steps: [String]
}

/// On-device triage using Apple Foundation Models. Nothing leaves the Mac.
public struct Triager: Sendable {
    // The on-device model has a small context window, so threads are trimmed hard.
    private static let maxChars = 6000
    /// Greedy decoding: the same thread always gets the same answer, so results are stable and the prompt can be tuned.
    private static let deterministic = GenerationOptions(samplingMode: .greedy)

    public init() {}

    public func suggest(for thread: GmailThread, me: String? = nil, prompt: String = TriagePrompts.local) async throws -> TriageSuggestion {
        try TriagePrompts.validate(prompt, maxBytes: TriagePrompts.localMaxBytes, source: "Local")
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw TriageError.modelUnavailable(String(describing: model.availability))
        }
        // Two independent requests, run together: the pair finishes in roughly 1.2x one request, not 2x.
        async let classification = Self.classify(thread, me: me, instructions: prompt)
        async let summary = Self.summarise(thread, me: me)
        let (t, longSummary) = try await (classification, summary)
        let bucket = TriageRules.bucket(whoActs: t.whoActs.rawValue, kind: t.kind.rawValue, asksUser: t.asksUser)
        return TriageSuggestion(
            bucket: bucket,
            nextAction: bucket == .nextAction || bucket == .project ? t.nextAction : "",
            summary: longSummary,
            waitingOn: bucket == .waitingFor && !t.waitingOn.isEmpty ? t.waitingOn : nil)
    }

    private static func classify(_ thread: GmailThread, me: String?, instructions: String) async throws -> GeneratedTriage {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt(for: thread, me: me), generating: GeneratedTriage.self, options: deterministic).content
    }

    private static func summarise(_ thread: GmailThread, me: String?) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You summarise email for the person who received it. Messages marked (you) were written by \
            that person. Use only facts stated in the email: never guess or invent dates, names or numbers, \
            and do not mention when the email was sent. Name only people who appear in the From lines or \
            the text. Describe what the email says; do not give advice and do not say whether anything needs doing.
            """)
        let prompt = "Summarise this email thread (newest message first).\n\n" + transcript(for: thread, me: me)
        return try await session.respond(to: prompt, generating: GeneratedSummary.self, options: deterministic).content.summary
    }

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
        let r = try await session.respond(to: Self.prompt(for: thread), generating: GeneratedPlan.self, options: Self.deterministic)
        return ProjectPlan(summary: r.content.summary, steps: r.content.steps)
    }

    /// The thread as plain text for the model: newest first, quoted replies and tracking links dropped,
    /// trimmed to fit its small context window.
    static func transcript(for thread: GmailThread, me: String?) -> String {
        var budget = maxChars
        var chunks: [String] = []
        let isMine = { (m: GmailMessage) in me.map { m.from.localizedCaseInsensitiveContains($0) } ?? false }
        for m in (thread.messages ?? []).reversed() {
            let body = m.plainText.modelFriendly.split(separator: "\n", omittingEmptySubsequences: true)
                .filter { !$0.hasPrefix(">") }.joined(separator: "\n")
            let chunk = "From: \(m.from)\(isMine(m) ? " (you)" : "")\nSubject: \(m.subject)\n\(body.prefix(max(0, min(budget, 2500))))"
            budget -= chunk.count
            chunks.append(chunk)
            if budget <= 0 { break }
        }
        return chunks.joined(separator: "\n---\n")
    }

    static func prompt(for thread: GmailThread, me: String? = nil) -> String {
        let isMine = { (m: GmailMessage) in me.map { m.from.localizedCaseInsensitiveContains($0) } ?? false }
        let lastBy = thread.messages?.last.map { isMine($0) ? "the user" : "someone else" } ?? "unknown"
        // Only an unsubscribe header or bulk precedence is mentioned. A no-reply sender is left out on
        // purpose: receipts, bookings and confirmations come from those too, and hinting at it made the
        // model file them as junk.
        let strong = (thread.messages?.last?.bulkSignals ?? []).filter { !$0.contains("no-reply") }
        let signalLine = strong.isEmpty ? "" : " The last message \(strong.joined(separator: " and ")), so it is probably automated or bulk mail."
        return "Triage this email thread (newest message first). The last message was sent by \(lastBy).\(signalLine)\n\n"
            + transcript(for: thread, me: me)
    }
}

#else

public struct Triager: Sendable {
    public init() {}
    public func suggest(for thread: GmailThread, me: String? = nil, prompt: String = TriagePrompts.local) async throws -> TriageSuggestion {
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


extension String {
    /// The first sentence, using Foundation's sentence segmentation (it copes with "$2.50" and "Dr.").
    public var firstSentence: String {
        var first: String?
        enumerateSubstrings(in: startIndex..., options: .bySentences) { sentence, _, _, stop in
            first = sentence?.trimmingCharacters(in: .whitespacesAndNewlines)
            stop = true
        }
        return first ?? self
    }
}
