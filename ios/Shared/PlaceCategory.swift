import Foundation

/// The category table, written by hand from contracts/tables/categories.json.
/// Keep the two in step. Starters are Mimo's fixed suggestions per category
/// (design §4.9); they need no model call.
nonisolated extension CategorySlug {
    /// Display name, sentence case.
    var displayName: String {
        switch self {
        case .cafe: "Café"
        case .tea: "Tea shop"
        case .restaurant: "Restaurant"
        case .ramen: "Ramen"
        case .bar: "Bar"
        case .bakery: "Bakery"
        case .convenienceStore: "Convenience store"
        case .museum: "Museum"
        case .park: "Park"
        case .templeShrine: "Temple or shrine"
        case .shopping: "Shopping"
        case .transit: "Transit"
        case .hotel: "Hotel"
        case .other: "Place"
        }
    }

    /// SF Symbol name.
    var sfSymbol: String {
        switch self {
        case .cafe: "cup.and.saucer.fill"
        case .tea: "cup.and.heat.waves.fill"
        case .restaurant: "fork.knife"
        case .ramen: "fork.knife.circle.fill"
        case .bar: "wineglass.fill"
        case .bakery: "birthday.cake.fill"
        case .convenienceStore: "storefront.fill"
        case .museum: "building.columns.fill"
        case .park: "tree.fill"
        case .templeShrine: "bell.fill"
        case .shopping: "bag.fill"
        case .transit: "tram.fill"
        case .hotel: "bed.double.fill"
        case .other: "mappin.and.ellipse"
        }
    }

    /// Mimo's starter suggestions for this kind of place.
    var starters: [String] {
        switch self {
        case .cafe: ["What's good here?", "How do I order it less sweet?", "Plan my afternoon"]
        case .tea: ["What's popular here?", "How do I ask for less sugar and ice?", "How do I pay?"]
        case .restaurant: ["What should I order?", "Is there anything I should avoid?", "How do I pay?"]
        case .ramen: ["How does the ticket machine work?", "What should I order?", "How do I ask for firmer noodles?"]
        case .bar: ["What do locals drink here?", "Is there a cover charge?", "Somewhere quieter nearby?"]
        case .bakery: ["What's popular here?", "Which ones have nuts?", "How do I pay?"]
        case .convenienceStore: ["What's worth trying here?", "Can I top up a transit card here?", "How do I pay?"]
        case .museum: ["What shouldn't I miss?", "How long do I need here?", "Plan my afternoon"]
        case .park: ["What's nice to see here?", "Somewhere to eat nearby?", "Plan my afternoon"]
        case .templeShrine: ["How should I behave here?", "Can I take photos?", "Plan my afternoon"]
        case .shopping: ["What's worth buying here?", "Can I get a tax refund?", "How do I pay?"]
        case .transit: ["How do I buy a ticket?", "Which exit should I take?", "How do I get back to my hotel?"]
        case .hotel: ["Where should I eat tonight?", "Plan my morning", "How do I ask for a late checkout?"]
        case .other: ["What's around here?", "Plan my afternoon", "How do I pay?"]
        }
    }
}
