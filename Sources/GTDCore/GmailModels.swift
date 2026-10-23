import Foundation

public struct GmailLabel: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let type: String?
}

struct LabelList: Decodable { let labels: [GmailLabel]? }

public struct ThreadRef: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let snippet: String?

    public init(id: String, snippet: String?) {
        self.id = id
        self.snippet = snippet
    }

    private enum CodingKeys: String, CodingKey { case id, snippet }

    /// Gmail sends snippets HTML-escaped (`&#39;`, `&amp;`), so decode them for display.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet)?.htmlUnescaped
    }
}

struct ThreadList: Decodable {
    let threads: [ThreadRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

struct GmailProfile: Decodable { let emailAddress: String }

public struct GmailThread: Decodable, Sendable, Identifiable {
    public let id: String
    public let messages: [GmailMessage]?
}

public struct GmailMessage: Decodable, Sendable, Identifiable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let internalDate: String?
    public let payload: Part?

    public struct Part: Decodable, Sendable {
        public let mimeType: String?
        public let headers: [Header]?
        public let body: Body?
        public let parts: [Part]?
    }
    public struct Header: Decodable, Sendable { public let name: String; public let value: String }
    public struct Body: Decodable, Sendable { public let data: String? }

    public func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    public var subject: String { header("Subject") ?? "(no subject)" }
    public var from: String { header("From") ?? "" }
    public var date: Date? { internalDate.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } }
    public var isUnread: Bool { labelIds?.contains("UNREAD") ?? false }

    /// Best-effort plain text body: prefers text/plain, falls back to tag-stripped text/html.
    public var plainText: String {
        guard let payload else { return snippet?.htmlUnescaped ?? "" }
        if let text = Self.find("text/plain", in: payload) { return text }
        if let html = Self.find("text/html", in: payload) { return Self.stripHTML(html) }
        return snippet?.htmlUnescaped ?? ""
    }

    private static func find(_ mime: String, in part: Part) -> String? {
        if part.mimeType == mime, let data = part.body?.data, let decoded = decodeBase64URL(data) { return decoded }
        for child in part.parts ?? [] { if let hit = find(mime, in: child) { return hit } }
        return nil
    }

    static func decodeBase64URL(_ s: String) -> String? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<(style|script)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .htmlUnescaped
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


extension String {
    /// Decodes the common named entities plus numeric ones (`&#39;`, `&#x27;`).
    var htmlUnescaped: String {
        guard contains("&") else { return self }
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
                     "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}",
                     "&ndash;": "\u{2013}", "&mdash;": "\u{2014}", "&hellip;": "\u{2026}"]
        var out = ""
        var rest = self[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.prefix(12).firstIndex(of: ";") else { out.append("&"); rest = rest.dropFirst(); continue }
            let entity = String(rest[...semi])
            var replacement = named[entity.lowercased()]
            if replacement == nil, entity.hasPrefix("&#") {
                let digits = entity.dropFirst(2).dropLast()
                let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                replacement = code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
            if let replacement { out += replacement; rest = rest[rest.index(after: semi)...] }
            else { out.append("&"); rest = rest.dropFirst() }
        }
        return out + rest
    }
}
