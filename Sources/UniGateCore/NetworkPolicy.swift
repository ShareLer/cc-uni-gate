import Foundation

public enum NetworkPolicyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case direct

    public var id: String { rawValue }
}

public enum ProviderNetworkPolicyOverride: String, CaseIterable, Codable, Sendable, Identifiable {
    case inherit
    case system
    case direct

    public var id: String { rawValue }

    public var effectiveMode: NetworkPolicyMode? {
        switch self {
        case .inherit:
            return nil
        case .system:
            return .system
        case .direct:
            return .direct
        }
    }
}

public struct NetworkPolicyPreferences: Codable, Sendable, Equatable {
    public var globalMode: NetworkPolicyMode
    public var providerOverrides: [String: ProviderNetworkPolicyOverride]
    public var directDomainRules: [String]

    public init(
        globalMode: NetworkPolicyMode = .system,
        providerOverrides: [String: ProviderNetworkPolicyOverride] = [:],
        directDomainRules: [String] = []
    ) {
        self.globalMode = globalMode
        self.providerOverrides = providerOverrides.filter { $0.value != .inherit }
        self.directDomainRules = Self.normalizedDomainRules(directDomainRules)
    }

    public static func normalizedDomainRules(_ rules: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rule in rules {
            guard let normalized = normalizedDomainRule(rule), !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    public static func parseDomainRulesText(_ text: String) -> [String] {
        let lineSeparators = CharacterSet.newlines
        var values: [String] = []
        for line in text.components(separatedBy: lineSeparators) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix("domain,") || lowercased.hasPrefix("domain-suffix,") {
                values.append(trimmed)
            } else {
                values.append(contentsOf: trimmed.components(separatedBy: CharacterSet(charactersIn: ",\t ")))
            }
        }
        return normalizedDomainRules(values)
    }

    private static func normalizedDomainRule(_ value: String) -> String? {
        var rule = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        guard !rule.isEmpty else {
            return nil
        }

        if rule.hasPrefix("domain-suffix,") || rule.hasPrefix("domain,") {
            let parts = rule.split(separator: ",").map(String.init)
            guard parts.count >= 2 else {
                return nil
            }
            rule = parts[1]
        }

        if let url = URL(string: rule), let host = url.host {
            rule = host
        } else if let schemeRange = rule.range(of: "://") {
            rule = String(rule[schemeRange.upperBound...])
        }

        if let slashIndex = rule.firstIndex(of: "/") {
            rule = String(rule[..<slashIndex])
        }
        if let colonIndex = rule.lastIndex(of: ":"),
           rule[..<colonIndex].contains(".") {
            rule = String(rule[..<colonIndex])
        }
        rule = rule.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return rule.isEmpty ? nil : rule
    }
}

public struct NetworkPolicyDiagnostic: Codable, Sendable, Equatable, Identifiable {
    public var providerRef: ProviderRef
    public var appType: String
    public var providerName: String
    public var url: String
    public var systemError: String
    public var directStatusCode: Int
    public var checkedAt: Date

    public var id: String { providerRef.description }

    public init(
        providerRef: ProviderRef,
        appType: String,
        providerName: String,
        url: String,
        systemError: String,
        directStatusCode: Int,
        checkedAt: Date = Date()
    ) {
        self.providerRef = providerRef
        self.appType = appType
        self.providerName = providerName
        self.url = url
        self.systemError = systemError
        self.directStatusCode = directStatusCode
        self.checkedAt = checkedAt
    }
}

public enum NetworkPolicyResolver {
    public static func effectiveMode(
        preferences: NetworkPolicyPreferences,
        providerRef: ProviderRef?,
        host: String?
    ) -> NetworkPolicyMode {
        if let providerRef,
           let override = preferences.providerOverrides[providerRef.description]?.effectiveMode {
            return override
        }
        if let host, matchesAnyDomainRule(host: host, rules: preferences.directDomainRules) {
            return .direct
        }
        return preferences.globalMode
    }

    public static func matchesAnyDomainRule(host: String, rules: [String]) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalizedHost.isEmpty else {
            return false
        }
        return NetworkPolicyPreferences.normalizedDomainRules(rules).contains {
            matchesDomainRule(host: normalizedHost, rule: $0)
        }
    }

    private static func matchesDomainRule(host: String, rule: String) -> Bool {
        if rule.hasPrefix("*.") {
            let suffix = String(rule.dropFirst(2))
            return host.hasSuffix(".\(suffix)")
        }
        if rule.hasPrefix("*") {
            let suffix = String(rule.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        if rule.hasPrefix(".") {
            let suffix = String(rule.dropFirst())
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == rule || host.hasSuffix(".\(rule)")
    }
}
