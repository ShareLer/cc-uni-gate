import Foundation

public struct RequestMetricKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var appType: String
    public var routeKey: String
    public var providerRef: String
    public var providerName: String

    public init(appType: String, routeKey: String, providerRef: String, providerName: String) {
        self.appType = appType
        self.routeKey = routeKey
        self.providerRef = providerRef
        self.providerName = providerName
    }

    public var description: String {
        "\(ProviderDisplay.appTypeLabel(appType)) / \(routeKey) / \(providerName)"
    }
}

public struct RequestMetricRecord: Codable, Sendable, Equatable {
    public var totalCount: Int
    public var successCount: Int
    public var failureCount: Int
    public var providerFailureCount: Int
    public var totalLatencyMilliseconds: Double
    public var lastLatencyMilliseconds: Double?
    public var lastStatusCode: Int?
    public var lastError: String?
    public var updatedAt: Date?

    public init(
        totalCount: Int = 0,
        successCount: Int = 0,
        failureCount: Int = 0,
        providerFailureCount: Int = 0,
        totalLatencyMilliseconds: Double = 0,
        lastLatencyMilliseconds: Double? = nil,
        lastStatusCode: Int? = nil,
        lastError: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.totalCount = totalCount
        self.successCount = successCount
        self.failureCount = failureCount
        self.providerFailureCount = providerFailureCount
        self.totalLatencyMilliseconds = totalLatencyMilliseconds
        self.lastLatencyMilliseconds = lastLatencyMilliseconds
        self.lastStatusCode = lastStatusCode
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    public var averageLatencyMilliseconds: Double? {
        guard totalCount > 0 else {
            return nil
        }
        return totalLatencyMilliseconds / Double(totalCount)
    }

    public mutating func record(
        statusCode: Int?,
        latencyMilliseconds: Double,
        errorMessage: String?,
        providerFailure: Bool,
        at date: Date = Date()
    ) {
        totalCount += 1
        if let statusCode, (200..<400).contains(statusCode), errorMessage == nil {
            successCount += 1
        } else {
            failureCount += 1
        }
        if providerFailure {
            providerFailureCount += 1
        }
        totalLatencyMilliseconds += latencyMilliseconds
        lastLatencyMilliseconds = latencyMilliseconds
        lastStatusCode = statusCode
        lastError = errorMessage
        updatedAt = date
    }
}

public struct RequestMetricsState: Codable, Sendable, Equatable {
    public var records: [RequestMetricKey: RequestMetricRecord]

    public init(records: [RequestMetricKey: RequestMetricRecord] = [:]) {
        self.records = records
    }

    public mutating func record(
        key: RequestMetricKey,
        statusCode: Int?,
        latencyMilliseconds: Double,
        errorMessage: String? = nil,
        providerFailure: Bool = false,
        at date: Date = Date()
    ) {
        var record = records[key] ?? RequestMetricRecord()
        record.record(
            statusCode: statusCode,
            latencyMilliseconds: latencyMilliseconds,
            errorMessage: errorMessage,
            providerFailure: providerFailure,
            at: date
        )
        records[key] = record
    }

    public func records(appType: String) -> [(RequestMetricKey, RequestMetricRecord)] {
        records
            .filter { $0.key.appType == appType }
            .sorted { lhs, rhs in
                lhs.key.description.localizedStandardCompare(rhs.key.description) == .orderedAscending
            }
    }
}

