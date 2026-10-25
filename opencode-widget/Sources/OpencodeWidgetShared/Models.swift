import Foundation

public struct ProviderBalance: Codable, Equatable {
    public var balance: Double?
    public var currency: String

    public init(balance: Double? = nil, currency: String = "USD") {
        self.balance = balance
        self.currency = currency
    }
}

public struct DailyUsageRow: Codable, Identifiable, Equatable {
    public var id: String { date }
    public let date: String
    public var deepseekTokens: Int
    public var deepseekCost: Double
    public var minimaxTokens: Int
    public var minimaxCost: Double

    public init(date: String, deepseekTokens: Int = 0, deepseekCost: Double = 0, minimaxTokens: Int = 0, minimaxCost: Double = 0) {
        self.date = date
        self.deepseekTokens = deepseekTokens
        self.deepseekCost = deepseekCost
        self.minimaxTokens = minimaxTokens
        self.minimaxCost = minimaxCost
    }

    public var totalTokens: Int { deepseekTokens + minimaxTokens }
    public var totalCost: Double { deepseekCost + minimaxCost }
}

public struct MiniMaxUsage: Codable, Equatable {
    public var remainingPrompts: Int
    public var totalPrompts: Int

    public init(remainingPrompts: Int = 0, totalPrompts: Int = 0) {
        self.remainingPrompts = remainingPrompts
        self.totalPrompts = totalPrompts
    }

    public var percentage: Double {
        totalPrompts > 0 ? Double(remainingPrompts) / Double(totalPrompts) : 0
    }
}

public struct MiniMaxModelRemain: Codable, Identifiable, Equatable {
    public var id: String { modelName }
    public let modelName: String
    public let currentIntervalTotalCount: Int
    public let currentIntervalRemainingCount: Int
    public let startTime: Int64
    public let endTime: Int64
    public let remainsTime: Int64

    public init(modelName: String, currentIntervalTotalCount: Int, currentIntervalRemainingCount: Int, startTime: Int64, endTime: Int64, remainsTime: Int64) {
        self.modelName = modelName
        self.currentIntervalTotalCount = currentIntervalTotalCount
        self.currentIntervalRemainingCount = currentIntervalRemainingCount
        self.startTime = startTime
        self.endTime = endTime
        self.remainsTime = remainsTime
    }

    public var usagePercentage: Double {
        guard currentIntervalTotalCount > 0 else { return 0 }
        return Double(currentIntervalTotalCount - currentIntervalRemainingCount) / Double(currentIntervalTotalCount)
    }
}

public struct MiniMaxCodingPlanResponse: Codable {
    public let modelRemains: [MiniMaxModelRemain]
    public let baseResp: MiniMaxBaseResp?

    public init(modelRemains: [MiniMaxModelRemain], baseResp: MiniMaxBaseResp?) {
        self.modelRemains = modelRemains
        self.baseResp = baseResp
    }
}

public struct MiniMaxBaseResp: Codable {
    public let statusCode: Int
    public let statusMsg: String?
}

public struct ModelUsageRow: Codable, Identifiable, Equatable {
    public var id: String { "\(date)-\(provider)-\(modelId)" }
    public let date: String
    public let provider: String
    public let modelId: String
    public let tokens: Int
    public let cost: Double

    public init(date: String, provider: String, modelId: String, tokens: Int, cost: Double) {
        self.date = date
        self.provider = provider
        self.modelId = modelId
        self.tokens = tokens
        self.cost = cost
    }
}

public struct OpenAIQuota: Codable, Equatable, Sendable {
    public var remainingPercent: Double?
    public var resetDate: Date?
    public var fiveHourRemainingPercent: Double?
    public var fiveHourResetDate: Date?

    public init(remainingPercent: Double? = nil, resetDate: Date? = nil, fiveHourRemainingPercent: Double? = nil, fiveHourResetDate: Date? = nil) {
        self.remainingPercent = remainingPercent
        self.resetDate = resetDate
        self.fiveHourRemainingPercent = fiveHourRemainingPercent
        self.fiveHourResetDate = fiveHourResetDate
    }
}

public struct HourlyUsageBucket: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { hour }
    public let hour: Date
    public let openAIInputTokens: Int64
    public let deepseekInputTokens: Int64
    public let smoothedOpenAIInputTokens: Double
    public let smoothedDeepseekInputTokens: Double

    public init(
        hour: Date,
        openAIInputTokens: Int64 = 0,
        deepseekInputTokens: Int64 = 0,
        smoothedOpenAIInputTokens: Double? = nil,
        smoothedDeepseekInputTokens: Double? = nil
    ) {
        self.hour = hour
        self.openAIInputTokens = openAIInputTokens
        self.deepseekInputTokens = deepseekInputTokens
        self.smoothedOpenAIInputTokens = smoothedOpenAIInputTokens ?? Double(openAIInputTokens)
        self.smoothedDeepseekInputTokens = smoothedDeepseekInputTokens ?? Double(deepseekInputTokens)
    }
}

/// Continuous, server-anchored reset-cycle math. Weekly remains the default;
/// display text may round hours, but marker positions never do.
public struct QuotaResetTimeline: Sendable, Equatable {
    public static let cycleHours: Double = 168

    public let resetDate: Date
    public let durationHours: Double

    public init(resetDate: Date, cycleHours: Double = Self.cycleHours) {
        self.resetDate = resetDate
        self.durationHours = cycleHours
    }

    public func isValid(at now: Date) -> Bool {
        durationHours.isFinite && durationHours > 0 &&
        resetDate.timeIntervalSinceReferenceDate.isFinite &&
        now.timeIntervalSinceReferenceDate.isFinite &&
        resetDate.timeIntervalSince(now).isFinite
    }

    /// Fractional hours remaining until reset (clamped ≥ 0; 0 after reset).
    public func remainingHours(at now: Date = Date()) -> Double {
        guard isValid(at: now) else { return 0 }
        return max(0, resetDate.timeIntervalSince(now) / 3600)
    }

    /// Elapsed hours in the cycle = `cycleHours − remaining hours`,
    /// clamped to 0...cycleHours.
    public func elapsedHours(at now: Date = Date()) -> Double {
        guard isValid(at: now) else { return 0 }
        return min(durationHours, max(0, durationHours - remainingHours(at: now)))
    }

    /// Marker x-fraction (0...1) of the bar width for the given instant.
    public func elapsedFraction(at now: Date = Date()) -> Double {
        guard isValid(at: now) else { return 0 }
        return min(1, max(0, elapsedHours(at: now) / durationHours))
    }
}

public struct DeepSeekBalanceSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { hour }
    public let hour: Date
    public let remainingRM: Double

    public init(hour: Date, remainingRM: Double) {
        self.hour = hour
        self.remainingRM = remainingRM
    }
}

public enum DeepSeekBalanceHistory {
    public static let maximumHours = 720
    public static let usdToMYR = 4.5

    public static func appending(
        balanceUSD: Double?,
        at date: Date,
        to snapshots: [DeepSeekBalanceSnapshot]
    ) -> [DeepSeekBalanceSnapshot] {
        guard let balanceUSD, balanceUSD.isFinite, balanceUSD >= 0 else { return snapshots }
        let timestamp = floor(date.timeIntervalSince1970 / 3_600) * 3_600
        let snapshot = DeepSeekBalanceSnapshot(
            hour: Date(timeIntervalSince1970: timestamp),
            remainingRM: balanceUSD * usdToMYR
        )
        var result = snapshots.filter { $0.hour != snapshot.hour }
        result.append(snapshot)
        result.sort { $0.hour < $1.hour }
        return Array(result.suffix(maximumHours))
    }
}

public struct OpenAIQuotaSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { hour }
    public let hour: Date
    public let remainingPercent: Double

    public init(hour: Date, remainingPercent: Double) {
        self.hour = hour
        self.remainingPercent = remainingPercent
    }
}

public enum OpenAIQuotaHistory {
    public static let maximumHours = 720

    public static func appending(
        remainingPercent: Double?,
        at date: Date,
        to snapshots: [OpenAIQuotaSnapshot]
    ) -> [OpenAIQuotaSnapshot] {
        guard let remainingPercent,
              remainingPercent.isFinite,
              (0...100).contains(remainingPercent) else { return snapshots }
        let timestamp = floor(date.timeIntervalSince1970 / 3_600) * 3_600
        let snapshot = OpenAIQuotaSnapshot(
            hour: Date(timeIntervalSince1970: timestamp),
            remainingPercent: remainingPercent
        )
        var result = snapshots.filter { $0.hour != snapshot.hour }
        result.append(snapshot)
        result.sort { $0.hour < $1.hour }
        return Array(result.suffix(maximumHours))
    }
}

public struct WidgetCache: Codable {
    public let lastUpdated: Date
    public var deepseek: ProviderBalance
    public var minimax: ProviderBalance
    public var minimaxUsage: MiniMaxUsage?
    public var minimaxCredit: Double?
    public var minimaxCreditFetched: Date?
    public var dailyUsage: [DailyUsageRow]
    public var openAIQuota: OpenAIQuota?
    public var hourlyUsage: [HourlyUsageBucket]
    public var deepseekBalanceHistory: [DeepSeekBalanceSnapshot]
    public var openAIQuotaHistory: [OpenAIQuotaSnapshot]
    public var usageHistoryWarning: String?

    public init(lastUpdated: Date = Date(), deepseek: ProviderBalance = ProviderBalance(), minimax: ProviderBalance = ProviderBalance(), minimaxUsage: MiniMaxUsage? = nil, minimaxCredit: Double? = nil, minimaxCreditFetched: Date? = nil, dailyUsage: [DailyUsageRow] = [], openAIQuota: OpenAIQuota? = nil, hourlyUsage: [HourlyUsageBucket] = [], deepseekBalanceHistory: [DeepSeekBalanceSnapshot] = [], openAIQuotaHistory: [OpenAIQuotaSnapshot] = [], usageHistoryWarning: String? = nil) {
        self.lastUpdated = lastUpdated
        self.deepseek = deepseek
        self.minimax = minimax
        self.minimaxUsage = minimaxUsage
        self.minimaxCredit = minimaxCredit
        self.minimaxCreditFetched = minimaxCreditFetched
        self.dailyUsage = dailyUsage
        self.openAIQuota = openAIQuota
        self.hourlyUsage = hourlyUsage
        self.deepseekBalanceHistory = deepseekBalanceHistory
        self.openAIQuotaHistory = openAIQuotaHistory
        self.usageHistoryWarning = usageHistoryWarning
    }

    private enum CodingKeys: String, CodingKey {
        case lastUpdated, deepseek, minimax, minimaxUsage, minimaxCredit
        case minimaxCreditFetched, dailyUsage, openAIQuota, hourlyUsage, deepseekBalanceHistory, openAIQuotaHistory
        case usageHistoryWarning
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lastUpdated = try values.decode(Date.self, forKey: .lastUpdated)
        deepseek = try values.decode(ProviderBalance.self, forKey: .deepseek)
        minimax = try values.decode(ProviderBalance.self, forKey: .minimax)
        minimaxUsage = try values.decodeIfPresent(MiniMaxUsage.self, forKey: .minimaxUsage)
        minimaxCredit = try values.decodeIfPresent(Double.self, forKey: .minimaxCredit)
        minimaxCreditFetched = try values.decodeIfPresent(Date.self, forKey: .minimaxCreditFetched)
        dailyUsage = try values.decodeIfPresent([DailyUsageRow].self, forKey: .dailyUsage) ?? []
        openAIQuota = try values.decodeIfPresent(OpenAIQuota.self, forKey: .openAIQuota)
        hourlyUsage = try values.decodeIfPresent([HourlyUsageBucket].self, forKey: .hourlyUsage) ?? []
        deepseekBalanceHistory = try values.decodeIfPresent([DeepSeekBalanceSnapshot].self, forKey: .deepseekBalanceHistory) ?? []
        openAIQuotaHistory = try values.decodeIfPresent([OpenAIQuotaSnapshot].self, forKey: .openAIQuotaHistory) ?? []
        usageHistoryWarning = try values.decodeIfPresent(String.self, forKey: .usageHistoryWarning)
    }

    public var isEmpty: Bool {
        dailyUsage.isEmpty && hourlyUsage.isEmpty && deepseek.balance == nil && minimax.balance == nil && openAIQuota == nil && openAIQuotaHistory.isEmpty
    }
}
