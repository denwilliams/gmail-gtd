import Foundation
import GTDCore

let usage = """
gtd: Gmail GTD from the terminal (add --demo for sample mail, no sign-in)

  gtd login [--client-id ID] [--client-secret S]   Sign in via browser
  gtd logout                                       Forget stored tokens
  gtd setup                                        Create the GTD/* labels
  gtd today                                        Next actions, waiting-for, inbox count
  gtd open <thread-id>                             Open a thread in Gmail
  gtd inbox [N]                                    List inbox threads
  gtd list <bucket> [N]                            List a bucket
  gtd show <thread-id>                             Print a thread
  gtd file <thread-id> <bucket>                    File into a bucket (archives from inbox)
  gtd unfile <thread-id>                           Return to inbox
  gtd suggest <thread-id>                          On-device triage suggestion
  gtd process [N]                                  Walk the inbox interactively

Buckets: next, waiting, someday, reference, project
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func openInBrowser(_ url: URL) {
    print("Opening browser to sign in…\nIf nothing opens, visit:\n\(url)\n")
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/open")
    p.arguments = [url.absoluteString]
    try? p.run()
}

func option(_ name: String, in args: [String]) -> String? {
    args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}

func bucketArg(_ s: String?) -> GTDBucket {
    guard let s, let b = GTDBucket(cliName: s) else { fail("Unknown bucket. Use: next, waiting, someday, reference, project") }
    return b
}

/// `--demo` (or GMAIL_GTD_DEMO=1) runs against in-memory sample mail that resets every run.
let demoMode = CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["GMAIL_GTD_DEMO"] == "1"
let demoService = DemoMailService()

func connect() throws -> (any MailService, LabelManager) {
    if demoMode { return (demoService, LabelManager(client: demoService)) }
    guard let config = OAuthConfig.load() else { throw GmailError.notConfigured }
    let client = try GmailClient(auth: GmailAuth(config: config))
    return (client, LabelManager(client: client))
}

func line(_ t: GmailThread, bucket: GTDBucket? = nil) -> String {
    guard let m = t.messages?.last else { return t.id }
    let from = m.from.components(separatedBy: " <").first ?? m.from
    let flag = (t.messages?.contains { $0.isUnread } ?? false) ? "●" : " "
    let tag = bucket.map { " [\($0.title)]" } ?? ""
    return "\(flag) \(t.id)  \(from.prefix(24).padding(toLength: 24, withPad: " ", startingAt: 0))  \(m.subject.prefix(60))\(tag)"
}

func listThreads(labelID: String, limit: Int, client: any MailService) async throws {
    let refs = try await client.listThreads(labelIDs: [labelID], max: limit)
    if refs.isEmpty { print("Nothing here."); return }
    for ref in refs { print(line(try await client.thread(ref.id))) }
}

func printThread(_ t: GmailThread) {
    for m in t.messages ?? [] {
        print("From: \(m.from)\nDate: \(m.date?.formatted() ?? "")\nSubject: \(m.subject)\n\n\(m.plainText)\n\n────────\n")
    }
}

func printSuggestion(_ s: TriageSuggestion) {
    print("Suggested: \(s.bucket.title)")
    if !s.nextAction.isEmpty { print("Next:      \(s.nextAction)") }
    if let w = s.waitingOn { print("Waiting:   \(w)") }
    print("Summary:   \(s.summary)")
}

func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--demo" }
    guard !args.isEmpty else { print(usage); return }
    let cmd = args.removeFirst()

    switch cmd {
    case "login":
        let existing = OAuthConfig.load()
        guard let id = option("--client-id", in: args) ?? existing?.clientID else { throw GmailError.notConfigured }
        let config = OAuthConfig(clientID: id, clientSecret: option("--client-secret", in: args) ?? existing?.clientSecret)
        config.save()
        _ = try await GmailAuth(config: config).signIn(openURL: openInBrowser)
        print("Signed in.")
    case "logout":
        TokenStore.clear(); print("Signed out.")
    case "setup":
        let (_, labels) = try connect()
        for (bucket, _) in try await labels.ensureLabels().sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("✓ \(bucket.labelName)")
        }
    case "bench":
        // Dev tool: is the on-device model faster with concurrent requests?
        let (client, _) = try connect()
        let refs = try await client.listThreads(labelIDs: ["INBOX"], max: args.first.flatMap(Int.init) ?? 8)
        var threads: [GmailThread] = []
        for ref in refs { threads.append(try await client.thread(ref.id, full: true)) }
        let triager = Triager()
        _ = try await triager.suggest(for: threads[0], me: nil)   // warm-up
        let clock = ContinuousClock()
        let seq = try await clock.measure { for t in threads { _ = try await triager.suggest(for: t, me: nil) } }
        print("sequential, \(threads.count) threads: \(seq)")
        for width in [2, 4] {
            let par = try await clock.measure {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var next = 0
                    func add() { if next < threads.count { let t = threads[next]; next += 1; group.addTask { _ = try await triager.suggest(for: t, me: nil) } } }
                    for _ in 0..<width { add() }
                    while try await group.next() != nil { add() }
                }
            }
            print("concurrent x\(width): \(par)")
        }
    case "today":
        let (client, labels) = try connect()
        let ids = try await labels.ensureLabels()
        print("Next Actions")
        try await listThreads(labelID: ids[.nextAction]!, limit: 10, client: client)
        print("\nWaiting For")
        try await listThreads(labelID: ids[.waitingFor]!, limit: 10, client: client)
        print("\nInbox: \(try await client.threadCount(labelID: "INBOX")) threads")
    case "open":
        guard let id = args.first else { fail(usage) }
        let email = try? await connect().0.emailAddress()
        if demoMode { print("Demo mode: would open \(GmailLinks.thread(id, account: email))"); return }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/open")
        p.arguments = [GmailLinks.thread(id, account: email).absoluteString]
        try p.run()
    case "inbox":
        let (client, _) = try connect()
        try await listThreads(labelID: "INBOX", limit: args.first.flatMap(Int.init) ?? 20, client: client)
    case "list":
        let (client, labels) = try connect()
        let bucket = bucketArg(args.first)
        let id = try await labels.ensureLabels()[bucket]!
        try await listThreads(labelID: id, limit: args.dropFirst().first.flatMap(Int.init) ?? 20, client: client)
    case "show":
        guard let id = args.first else { fail(usage) }
        printThread(try await connect().0.thread(id, full: true))
    case "file":
        guard args.count == 2 else { fail(usage) }
        let (_, labels) = try connect()
        let bucket = bucketArg(args[1])
        try await labels.file(thread: args[0], into: bucket)
        print("Filed → \(bucket.title)")
    case "unfile":
        guard let id = args.first else { fail(usage) }
        try await connect().1.unfile(thread: id)
        print("Back in inbox.")
    case "suggest":
        guard let id = args.first else { fail(usage) }
        let client = try connect().0
        let thread = try await client.thread(id, full: true)
        printSuggestion(try await Triager().suggest(for: thread, me: try? await client.emailAddress()))
    case "process":
        try await process(limit: args.first.flatMap(Int.init) ?? 20)
    default:
        print(usage)
    }
}

/// Interactive inbox processing: one thread at a time, with an AI suggestion.
func process(limit: Int) async throws {
    let (client, labels) = try connect()
    let refs = try await client.listThreads(labelIDs: ["INBOX"], max: limit)
    let triager = Triager()
    let myEmail = try? await client.emailAddress()
    for ref in refs {
        let thread = try await client.thread(ref.id, full: true)
        print("\n" + String(repeating: "━", count: 60))
        if let m = thread.messages?.last {
            print("\(m.from)\n\(m.subject)\n\n\(m.plainText.prefix(600))")
        }
        var suggestion: TriageSuggestion?
        do { suggestion = try await triager.suggest(for: thread, me: myEmail); print(); printSuggestion(suggestion!) }
        catch { print("\n(no suggestion: \(error.localizedDescription))") }

        while true {
            print("\n[1]next [2]waiting [3]someday [4]ref [5]project [a]ccept [k]eep [q]uit > ", terminator: "")
            guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return }
            if input == "q" { return }
            if input == "k" || input.isEmpty { break }
            let bucket: GTDBucket? = input == "a" ? suggestion?.bucket
                : GTDBucket.allCases.first { String($0.shortcut) == input }
            if let bucket { try await labels.file(thread: thread.id, into: bucket); print("→ \(bucket.title)"); break }
        }
    }
    print("\nDone.")
}

do { try await run() } catch { fail(error.localizedDescription) }
