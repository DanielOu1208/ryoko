import Foundation

/// Mimo's starter questions (design §4.9): the category table's starters for
/// the place (`CategorySlug.starters`, mirrored from contracts/tables), plus a
/// "Plan my …" starter. Fixed templates; no model call.
enum MimoStarters {
    /// The category's starters with one plan starter for the part of the day
    /// at the place: "Plan my morning", "Plan my afternoon" or "Plan my
    /// evening". A plan starter already in the table takes the same wording, so
    /// there's never two.
    static func list(for category: CategorySlug, situation: Situation?) -> [String] {
        let plan = planStarter(for: situation)
        var starters = category.starters.map { isPlanStarter($0) ? plan : $0 }
        if !starters.contains(plan) { starters.append(plan) }
        var seen = Set<String>()
        return starters.filter { seen.insert($0).inserted }
    }

    /// "Plan my afternoon" by default; the morning or evening when that's
    /// what's next at the place.
    static func planStarter(for situation: Situation?) -> String {
        guard let situation, let part = PartOfDay(situation: situation) else { return "Plan my afternoon" }
        switch part {
        case .morning: return "Plan my morning"
        case .midday: return "Plan my afternoon"
        case .evening, .night: return "Plan my evening"
        }
    }

    private static func isPlanStarter(_ starter: String) -> Bool {
        starter.hasPrefix("Plan my ")
    }
}
