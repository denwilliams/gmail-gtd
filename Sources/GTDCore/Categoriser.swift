import Foundation

public enum CategorisationSource: Hashable, Sendable { case local, jev }

public enum CategorisationEvent: Sendable {
    case local(TriageSuggestion), localFailure(String), jev(GTDBucket), jevFailure(String)
}

/// Independent child tasks publish results as each finishes. Jev failure cannot cancel local work.
public struct Categoriser: Sendable {
    public typealias Local = @Sendable (GmailThread, String?, String) async throws -> TriageSuggestion
    public typealias Remote = @Sendable (GmailThread, String?, String, String) async throws -> GTDBucket
    private let local: Local
    private let remote: Remote

    public init(local: @escaping Local = { try await Triager().suggest(for: $0, me: $1, prompt: $2) },
                remote: @escaping Remote = { try await JevClient().categorise($0, me: $1, prompt: $2, token: $3) }) {
        self.local = local
        self.remote = remote
    }

    public func evaluate(_ thread: GmailThread, me: String?, settings: CategorisationSettings, token: String?) async -> CategorisationOutput {
        let collector = CategorisationCollector()
        await run(thread, me: me, settings: settings, token: token) { await collector.record($0) }
        return await collector.output
    }

    public func run(_ thread: GmailThread, me: String?, settings: CategorisationSettings, token: String?,
                    sources: Set<CategorisationSource> = [.local, .jev],
                    onResult: @escaping @Sendable (CategorisationEvent) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            if sources.contains(.local) {
                group.addTask {
                    do { await onResult(.local(try await local(thread, me, settings.localPrompt))) }
                    catch { await onResult(.localFailure(error.localizedDescription)) }
                }
            }
            if sources.contains(.jev) && settings.jevEnabled {
                group.addTask {
                    do { await onResult(.jev(try await remote(thread, me, settings.jevPrompt, token ?? ""))) }
                    catch { await onResult(.jevFailure(error.localizedDescription)) }
                }
            }
        }
    }
}
