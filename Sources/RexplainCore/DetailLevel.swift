import Foundation

public enum DetailLevel: String, Codable, CaseIterable, Sendable {
    case compact = "compact"
    case standard = "standard"
    case firstPrinciples = "first-principles"

    public static let defaultLevel: DetailLevel = .compact

    public static func parse(_ raw: String) -> DetailLevel? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "compact", "1", "brief", "quick":
            return .compact
        case "standard", "2", "medium":
            return .standard
        case "first-principles", "first_principles", "firstprinciples", "deep", "full", "3":
            return .firstPrinciples
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .firstPrinciples: return "First-principles"
        }
    }

    public var pickerSubtitle: String {
        switch self {
        case .compact:
            return "3–5 lines · Core definition, mechanism, and takeaway"
        case .standard:
            return "6–10 steps · Key terms, mechanism, and consequences"
        case .firstPrinciples:
            return "Up to 14–22 steps · Axioms, definitions, full derivation, edge cases, and example"
        }
    }

    public var stepRange: ClosedRange<Int> {
        switch self {
        case .compact: return 3...5
        case .standard: return 6...10
        case .firstPrinciples: return 14...22
        }
    }

    public var stepRangeDescription: String {
        "\(stepRange.lowerBound)–\(stepRange.upperBound) steps"
    }

    public var safetyMaxResponseTokens: Int {
        switch self {
        case .compact: return 450
        case .standard: return 1_100
        case .firstPrinciples: return 2_600
        }
    }
}
