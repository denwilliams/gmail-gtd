import Foundation

/// The GTD buckets, each backed by a nested Gmail label.
public enum GTDBucket: String, CaseIterable, Codable, Sendable {
    case nextAction, waitingFor, someday, reference, project, noise, done

    public static let labelPrefix = "GTD"

    public var title: String {
        switch self {
        case .nextAction: "Next Action"
        case .waitingFor: "Waiting For"
        case .someday: "Someday/Maybe"
        case .reference: "Reference"
        case .project: "Project"
        case .noise: "Noise"
        case .done: "Done"
        }
    }

    /// Gmail label name. A slash nests the label under `GTD`.
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
        case .done: "7"
        }
    }

    public init?(labelName: String) {
        guard let match = Self.allCases.first(where: { $0.labelName == labelName }) else { return nil }
        self = match
    }

    public init?(cliName: String) {
        let key = cliName.lowercased().replacingOccurrences(of: "-", with: "")
        switch key {
        case "next", "nextaction", "n": self = .nextAction
        case "waiting", "waitingfor", "w": self = .waitingFor
        case "someday", "maybe", "s": self = .someday
        case "reference", "ref", "r": self = .reference
        case "project", "p": self = .project
        case "noise", "junk": self = .noise
        case "done", "d", "archive": self = .done
        default: return nil
        }
    }
}
