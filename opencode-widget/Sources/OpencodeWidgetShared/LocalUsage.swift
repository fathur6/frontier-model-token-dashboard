import Foundation

public enum LocalUsageProvider: String, Sendable { case openAI, deepseek }
public enum LocalUsageSource: String, CaseIterable, Sendable { case openCode, codex, hermes }
public enum LocalUsageAvailability: Sendable { case available, missing, failed }

/// Metadata only. IDs are local provenance, never credentials or account IDs.
public struct LocalUsageObservation: Sendable {
    public let source: LocalUsageSource
    public let id: String
    public let provider: LocalUsageProvider
    public let sessionID: String
    public let requestID: String
    public let hour: Date
    public let tokens: Int
    public let estimatedCostUSD: Double?

    public init(source: LocalUsageSource, id: String, provider: LocalUsageProvider,
                sessionID: String = "", requestID: String = "", hour: Date,
                tokens: Int, estimatedCostUSD: Double? = nil) {
        self.source = source
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.requestID = requestID
        self.hour = Date(timeIntervalSince1970: floor(hour.timeIntervalSince1970 / 3_600) * 3_600)
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    public static func key(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public struct LocalUsageBatch: Sendable {
    public let source: LocalUsageSource
    public let availability: LocalUsageAvailability
    public let observations: [LocalUsageObservation]

    public init(source: LocalUsageSource, availability: LocalUsageAvailability,
                observations: [LocalUsageObservation] = []) {
        self.source = source
        self.availability = availability
        self.observations = observations
    }
}

public struct LocalUsageSnapshot: Sendable {
    public let from: Date
    public let through: Date
    public let batches: [LocalUsageBatch]

    public init(from: Date, through: Date, batches: [LocalUsageBatch]) {
        self.from = from
        self.through = through
        self.batches = batches
    }

    public var hasFailures: Bool { batches.contains { $0.availability == .failed } }
    public var anyAvailable: Bool { batches.contains { $0.availability == .available } }
    public var observations: [LocalUsageObservation] {
        Self.deduplicated(batches.filter { $0.availability == .available }.flatMap(\.observations))
    }

    /// Same account is NOT an identity. Only exact session mirrors (Hermes) or
    /// explicit provider request IDs suppress records from another client.
    public static func deduplicated(_ observations: [LocalUsageObservation]) -> [LocalUsageObservation] {
        func sessionKey(_ observation: LocalUsageObservation) -> String {
            LocalUsageObservation.key([observation.provider.rawValue, observation.sessionID])
        }
        let directSessions = Set(observations.filter { $0.source != .hermes && !$0.sessionID.isEmpty }.map(sessionKey))
        var seen = Set<String>()
        var requests = Set<String>()
        let priority: [LocalUsageSource: Int] = [.openCode: 0, .codex: 1, .hermes: 2]
        return observations.sorted {
            let left = priority[$0.source]!, right = priority[$1.source]!
            return left == right ? $0.id < $1.id : left < right
        }.filter { observation in
            guard observation.source != .hermes || observation.sessionID.isEmpty || !directSessions.contains(sessionKey(observation)) else { return false }
            guard seen.insert(LocalUsageObservation.key([observation.source.rawValue, observation.id])).inserted else { return false }
            if !observation.requestID.isEmpty {
                return requests.insert(LocalUsageObservation.key([observation.provider.rawValue, observation.requestID])).inserted
            }
            return true
        }
    }
}
