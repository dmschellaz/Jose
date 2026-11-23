import Testing
@testable import RedlineCore

@Test func pricesSonnetAndOpus() {
    let t = TokenUsage(input: 10_000, output: 2_000)
    #expect(Pricing.cost(model: "claude-sonnet-5-5", tokens: t) == 0.04)   // 0.02 + 0.02
    #expect(Pricing.cost(model: "claude-opus-5-5", tokens: t) == 0.08)     // 0.04 + 0.04
    #expect(Pricing.cost(model: "unknown-model", tokens: t) == nil)
}

@Test func formatsCostAndTokens() {
    #expect(Pricing.format(0.0004) == "<$0.001")
    #expect(Pricing.format(0.0412) == "$0.041")
    #expect(Pricing.format(1.5) == "$1.50")
    #expect(Pricing.formatTokens(950) == "950")
    #expect(Pricing.formatTokens(12_345) == "12.3k")
}

@Test func reportResultCostUsesServingModel() {
    let r = ReportResult(itemCount: 1, usedAI: true, prompt: "", error: nil,
                         tokens: TokenUsage(input: 1_000_000, output: 0), model: "claude-opus-5-5")
    #expect(r.costUSD == 4)
    #expect(ReportResult(itemCount: 0, usedAI: false, prompt: "", error: nil, tokens: TokenUsage()).costUSD == nil)
}

@Test func summarisesModelTokensAndCost() {
    #expect(Pricing.displayName("claude-sonnet-5-5") == "Sonnet 5.5")
    #expect(Pricing.displayName("claude-opus-4-8") == "Opus 4.8")
    #expect(Pricing.summary(model: "claude-sonnet-5-5", tokens: TokenUsage(input: 12_345, output: 1_400))
            == "Sonnet 5.5 · 12.3k in · 1.4k out · $0.039")
    #expect(Pricing.summary(model: "mystery", tokens: TokenUsage(input: 10, output: 5)) == "Mystery · 10 in · 5 out")
}
