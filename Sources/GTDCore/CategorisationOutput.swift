import Foundation

public struct CategorisationOutput: Sendable {
    public var local: TriageSuggestion?
    public var localError: String?
    public var jev: JevState?
}

actor CategorisationCollector {
    var output = CategorisationOutput()
    func record(_ event: CategorisationEvent) {
        switch event {
        case .local(let suggestion): output.local = suggestion
        case .localFailure(let message): output.localError = message
        case .jev(let result): output.jev = .success(result.bucket, noiseLikelihood: result.noiseLikelihood)
        case .jevFailure(let message): output.jev = .failure(message)
        }
    }
}
