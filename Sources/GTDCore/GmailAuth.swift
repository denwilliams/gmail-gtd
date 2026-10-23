import Foundation
import CryptoKit
import Network

public enum GmailError: Error, LocalizedError {
    case notSignedIn, notConfigured, auth(String), http(Int, String), keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in. Run `gtd login` or use Sign In in the app."
        case .notConfigured: "No OAuth client ID. Set GMAIL_GTD_CLIENT_ID or save one in the app/`gtd login --client-id`."
        case .auth(let m): "Auth failed: \(m)"
        case .http(let code, let body): "Gmail API \(code): \(Self.summary(of: body))"
        case .keychain(let s): "Keychain error \(s)"
        }
    }

    /// Google error bodies are large JSON; show just the message (and the fix link when it gives one).
    static func summary(of body: String) -> String {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else { return String(body.prefix(300)) }
        return message
    }
}

/// OAuth client settings. Use a Google Cloud *Desktop app* client in an Internal consent screen.
public struct OAuthConfig: Codable, Sendable {
    public var clientID: String
    public var clientSecret: String?   // Desktop clients get one, but it is not confidential.

    public static let scope = "https://www.googleapis.com/auth/gmail.modify"
    private static let defaultsKey = "oauthConfig"

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static func load() -> OAuthConfig? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["GMAIL_GTD_CLIENT_ID"], !id.isEmpty {
            return OAuthConfig(clientID: id, clientSecret: env["GMAIL_GTD_CLIENT_SECRET"])
        }
        guard let data = UserDefaults(suiteName: "dev.denw.gmail-gtd")?.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(OAuthConfig.self, from: data)
    }

    public func save() {
        UserDefaults(suiteName: "dev.denw.gmail-gtd")?.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// Authorization-code flow with PKCE and a loopback redirect, so the same code serves the GUI and CLI.
public struct GmailAuth: Sendable {
    public let config: OAuthConfig
    public init(config: OAuthConfig) { self.config = config }

    /// Runs the browser sign-in. `openURL` is called with the consent URL (NSWorkspace in the app, `open` in the CLI).
    public func signIn(openURL: @Sendable (URL) -> Void) async throws -> Tokens {
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)

        let server = LoopbackServer()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: OAuthConfig.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        openURL(comps.url!)

        let params = try await server.waitForCallback()
        guard params["state"] == state else { throw GmailError.auth("state mismatch") }
        if let err = params["error"] { throw GmailError.auth(err) }
        guard let code = params["code"] else { throw GmailError.auth("no code returned") }

        let tokens = try await tokenRequest([
            "grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "redirect_uri": redirect,
        ], existingRefresh: nil)
        try TokenStore.save(tokens)
        return tokens
    }

    public func refresh(_ tokens: Tokens) async throws -> Tokens {
        let fresh = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": tokens.refreshToken],
                                           existingRefresh: tokens.refreshToken)
        try TokenStore.save(fresh)
        return fresh
    }

    private func tokenRequest(_ extra: [String: String], existingRefresh: String?) async throws -> Tokens {
        var form = extra
        form["client_id"] = config.clientID
        if let secret = config.clientSecret, !secret.isEmpty { form["client_secret"] = secret }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GmailError.auth(String(data: data, encoding: .utf8) ?? "token request failed")
        }
        struct Response: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let refresh = r.refresh_token ?? existingRefresh else { throw GmailError.auth("no refresh token") }
        return Tokens(accessToken: r.access_token, refreshToken: refresh, expiry: Date().addingTimeInterval(r.expires_in - 60))
    }

    private static func randomString(_ n: Int) -> String {
        Data((0..<n).map { _ in UInt8.random(in: .min ... .max) }).base64URL.prefix(n).description
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? self
    }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var early: [String: String]?   // callback that arrived before anyone was waiting
    private let queue = DispatchQueue(label: "gtd.loopback")

    init() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try! NWListener(using: params, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.first() { cont.resume(returning: listener.port!.rawValue) }
                case .failed(let e): if once.first() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let early = self.early { cont.resume(returning: early) } else { self.continuation = cont }
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let path = request.split(separator: " ").dropFirst().first,
                  let comps = URLComponents(string: String(path)), comps.path == "/" else { conn.cancel(); return }
            let params = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } })
            let body = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>Signed in</h2><p>You can close this tab.</p></body></html>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: reply.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            self.listener.cancel()
            if let cont = self.continuation { cont.resume(returning: params); self.continuation = nil }
            else { self.early = params }
        }
    }
}

/// Thread-safe "first caller wins" flag.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
