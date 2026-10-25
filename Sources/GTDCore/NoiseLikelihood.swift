import Foundation

/// Model estimates, not calibrated accuracy guarantees. Never infer a score from a category.
public enum NoiseLikelihood {
    public static func validated(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    public static func qualifies(bucket: GTDBucket?, score: Double?, threshold: Double) -> Bool {
        guard bucket == .noise, let score = validated(score), validated(threshold) != nil else { return false }
        return score >= threshold
    }
}

public struct JevClassification: Sendable {
    public let bucket: GTDBucket
    public let noiseLikelihood: Double?

    public init(bucket: GTDBucket, noiseLikelihood: Double? = nil) {
        self.bucket = bucket
        self.noiseLikelihood = NoiseLikelihood.validated(noiseLikelihood)
    }
}
