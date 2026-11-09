import Foundation

/// The 🚦 Status a thread is filed under, each backed by a nested Gmail label (`🚦/Next Action`).
/// A thread has exactly one status. In-tray (the processing queue) and Backlog are statuses in Gmail but not
/// filing destinations, so they are not cases here: see `LabelManager.inTrayLabelName` and `backlogLabelName`.
public enum GTDBucket: String, CaseIterable, Codable, Sendable {
    case nextAction, waitingFor, someday, reference, project, noise, junk

    public static let labelPrefix = "🚦"

    public var title: String {
        switch self {
        case .nextAction: "Next Action"
        case .waitingFor: "Waiting For"
        case .someday: "Someday/Maybe"
        case .reference: "Reference"
        case .project: "Project"
        case .noise: "Noise"
        case .junk: "Junk"
        }
    }

    /// Gmail label name. A slash nests the label under `🚦`.
    public var labelName: String {
        "\(Self.labelPrefix)/\(self == .someday ? "Someday" : title)"
    }

    public var shortcut: Character {
        switch self {
        case .nextAction: "1"
        case .waitingFor: "2"
        case .someday: "3"
        case .reference: "4"
        case .project: "5"
        case .noise: "6"
        case .junk: "7"
        }
    }

    /// Next Action, Waiting For and Someday stay in the Gmail Inbox; the rest are archived, never deleted.
    public var keepsInInbox: Bool {
        switch self {
        case .nextAction, .waitingFor, .someday: true
        case .reference, .project, .noise, .junk: false
        }
    }

    public init?(labelName: String) {
        let name = LabelFacet.normalised(labelName)
        guard let match = Self.allCases.first(where: { LabelFacet.normalised($0.labelName) == name }) else { return nil }
        self = match
    }

    /// Done was retired: finished work is Reference. Saved corrections, summaries and provider answers that
    /// still say "done" read as Reference rather than failing to load.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "done" { self = .reference; return }
        guard let bucket = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown status \(raw)"))
        }
        self = bucket
    }

    public init?(cliName: String) {
        let key = cliName.lowercased().replacingOccurrences(of: "-", with: "")
        switch key {
        case "next", "nextaction", "n": self = .nextAction
        case "waiting", "waitingfor", "w": self = .waitingFor
        case "someday", "maybe", "s": self = .someday
        case "reference", "ref", "r", "done", "d", "archive": self = .reference
        case "project", "p": self = .project
        case "noise": self = .noise
        case "junk", "spam", "j": self = .junk
        default: return nil
        }
    }
}
