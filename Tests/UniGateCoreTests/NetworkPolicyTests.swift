import UniGateCore
import Testing

struct NetworkPolicyTests {
    @Test
    func providerOverrideWinsOverDomainRuleAndGlobalDefault() {
        let ref = ProviderRef(appType: "claude", id: "dcc")
        let preferences = NetworkPolicyPreferences(
            globalMode: .direct,
            providerOverrides: [ref.description: .system],
            directDomainRules: ["intra.example.com"]
        )

        let mode = NetworkPolicyResolver.effectiveMode(
            preferences: preferences,
            providerRef: ref,
            host: "llm-proxy.intra.example.com"
        )

        #expect(mode == .system)
    }

    @Test
    func directDomainRulesMatchSuffixWildcardAndClashSyntax() {
        let rules = NetworkPolicyPreferences.parseDomainRulesText("""
        *.corp.example.com
        DOMAIN-SUFFIX,intra.example.com,DIRECT
        *internal.example.com
        """)

        #expect(NetworkPolicyResolver.matchesAnyDomainRule(
            host: "api.corp.example.com",
            rules: rules
        ))
        #expect(NetworkPolicyResolver.matchesAnyDomainRule(
            host: "llm-proxy.intra.example.com",
            rules: rules
        ))
        #expect(NetworkPolicyResolver.matchesAnyDomainRule(
            host: "llm-proxy.internal.example.com",
            rules: rules
        ))
        #expect(NetworkPolicyResolver.matchesAnyDomainRule(
            host: "internal.example.com",
            rules: rules
        ))
        #expect(!NetworkPolicyResolver.matchesAnyDomainRule(
            host: "notintra.example.net",
            rules: rules
        ))
        #expect(!NetworkPolicyResolver.matchesAnyDomainRule(
            host: "notinternal.example.com",
            rules: rules
        ))
    }

    @Test
    func domainRuleMatchesExactHostOnly() {
        let rules = NetworkPolicyPreferences.parseDomainRulesText("""
        DOMAIN,api.example.com,DIRECT
        DOMAIN-SUFFIX,intra.example.com,DIRECT
        """)

        #expect(NetworkPolicyResolver.matchesAnyDomainRule(
            host: "api.example.com",
            rules: rules
        ))
        #expect(!NetworkPolicyResolver.matchesAnyDomainRule(
            host: "sub.api.example.com",
            rules: rules
        ))
        #expect(NetworkPolicyResolver.matchesAnyDomainRule(
            host: "sub.intra.example.com",
            rules: rules
        ))
    }

    @Test
    func domainRuleFallsBackToGlobalWhenNoMatch() {
        let preferences = NetworkPolicyPreferences(
            globalMode: .system,
            directDomainRules: ["intra.example.com"]
        )

        #expect(NetworkPolicyResolver.effectiveMode(
            preferences: preferences,
            providerRef: nil,
            host: "api.public.example.com"
        ) == .system)
        #expect(NetworkPolicyResolver.effectiveMode(
            preferences: preferences,
            providerRef: nil,
            host: "llm.intra.example.com"
        ) == .direct)
    }

    @Test
    func modesExposeAlternatePolicy() {
        #expect(NetworkPolicyMode.system.alternate == .direct)
        #expect(NetworkPolicyMode.direct.alternate == .system)
    }
}
