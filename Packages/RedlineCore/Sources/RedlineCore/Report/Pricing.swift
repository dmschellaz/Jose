import Foundation

/// Standard Claude API prices in US dollars per million tokens (input, output).
/// Thinking tokens are billed as output and are included in usage.output_tokens.
public enum Pricing {
    static let perMillion: [String: (input: Double, output: Double)] = [
        "claude-sonnet-5-5": (2, 10),
        "claude-sonnet-5": (2, 10),
        "claude-opus-5-5": (4, 20),
        "claude-opus-5": (5, 25),
        "claude-opus-4-8": (5, 25),
        "claude-haiku-5-5": (0.1, 0.5),   // prompts up to 100K tokens
    ]

    public static func cost(model: String, tokens: TokenUsage) -> Double? {
        guard let p = perMillion[model] else { return nil }
        return (Double(tokens.input) * p.input + Double(tokens.output) * p.output) / 1_000_000
    }

    /// "$0.031", or "<$0.001" for tiny amounts.
    public static func format(_ usd: Double) -> String {
        if usd < 0.001 { return "<$0.001" }
        return usd < 1 ? String(format: "$%.3f", usd) : String(format: "$%.2f", usd)
    }

    /// "claude-sonnet-5-5" → "Sonnet 5.5".
    public static func displayName(_ model: String) -> String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    /// One line for the island: "Sonnet 5.5 · 12.3k in · 1.4k out · $0.041".
    public static func summary(model: String, tokens: TokenUsage) -> String {
        var s = "\(displayName(model)) · \(formatTokens(tokens.input)) in · \(formatTokens(tokens.output)) out"
        if let usd = cost(model: model, tokens: tokens) { s += " · " + format(usd) }
        return s
    }

    /// "12.3k" style token counts.
    public static func formatTokens(_ n: Int) -> String {
        n < 1000 ? "\(n)" : String(format: "%.1fk", Double(n) / 1000)
    }
}
