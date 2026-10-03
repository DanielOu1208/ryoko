import Foundation
import os

/// Builds the allergy card for Show mode (design §4.5):
/// - **Chip allergens** come from the bundled templates (`AllergyTemplates`), in
///   the local language, at the profile's severity. No network.
/// - **Free-text allergens** (`custom`, with a label) go to `POST /v1/allergy-card`.
///   Those lines are always unreviewed.
///
/// Cards are cached in memory per (language, home language, allergen and severity
/// pairs). Free-text answers are also saved to disk with the same key, so a card
/// that was built once still works offline.
@MainActor
final class AllergyCardStore {
    static let shared = AllergyCardStore()

    /// Why there's no card to show.
    enum Unavailable: Equatable {
        /// The profile skipped allergies (`nil`) or has none (`[]`).
        case noAllergies(skipped: Bool)
        /// No templates for this language yet (only `zh-Hans` and `ja` have them).
        case unsupportedLanguage(String)
    }

    /// `card(profile:language:api:)` was asked for a card `unavailability` rules out.
    struct UnavailableError: Error {
        var reason: Unavailable
    }

    /// The free-text call failed. `partial` is the card without those lines.
    struct FreeTextFailure: Error {
        var labels: [String]
        var message: String
        var partial: AllergyShowCard?
    }

    private var cards: [Key: AllergyShowCard] = [:]
    private var freeText: [String: AllergyCardResponse]
    private let fileURL: URL?

    init(fileURL: URL? = AllergyCardStore.defaultFileURL) {
        self.fileURL = fileURL
        freeText = Self.loadFreeText(from: fileURL)
    }

    // MARK: What can be shown

    /// The profile's allergies (plus, in DEBUG, `-RyokoExtraAllergy label:severity`).
    static func allergies(in profile: Profile) -> [Allergy]? {
        var allergies = profile.allergies
        #if DEBUG
        if let extra = ShowDebugOptions.extraAllergy {
            allergies = (allergies ?? []) + [extra]
        }
        #endif
        return allergies?.filter { $0.id != .custom || !($0.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Nil when a card can be built for `language`, otherwise why not.
    static func unavailability(profile: Profile, language: String) -> Unavailable? {
        guard let allergies = allergies(in: profile), !allergies.isEmpty else {
            return .noAllergies(skipped: profile.allergies == nil)
        }
        guard AllergyTemplates.bundled?.language(for: language) != nil else {
            return .unsupportedLanguage(language)
        }
        return nil
    }

    /// Template languages, for picking one when the situation's has none.
    static var templateLanguages: [LangCode] {
        let tags = Set(AllergyTemplates.bundled?.languages.keys.map(\.self) ?? [])
        return LangCode.allCases.filter { tags.contains($0.tag) }
    }

    /// "Peanuts, serious" or "Peanuts, kiwi and 1 more", in the home language.
    static func summary(profile: Profile, language: String) -> String {
        let allergies = allergies(in: profile) ?? []
        let templates = AllergyTemplates.bundled?.language(for: language)?.templates
            ?? AllergyTemplates.bundled?.languages.values.first
        let names = allergies.map { allergy -> String in
            if allergy.id == .custom { return allergy.label ?? "Other" }
            return templates?.allergen(allergy.id)?.nameHome ?? allergy.id.rawValue
        }
        guard let first = names.first else { return "" }
        if names.count == 1 {
            return "\(first.capitalizedFirst), \(allergies[0].severity.displayName.lowercased())"
        }
        if names.count == 2 {
            return "\(first.capitalizedFirst) and \(names[1])"
        }
        return "\(first.capitalizedFirst), \(names[1]) and \(names.count - 2) more"
    }

    // MARK: Building

    /// The card for `profile` in `language`. Throws `FreeTextFailure` when a
    /// free-text allergen couldn't be written (offline, server error) and isn't
    /// cached; its `partial` card has every template line.
    func card(profile: Profile, language: String, api: any RyokoAPI) async throws -> AllergyShowCard {
        if let reason = Self.unavailability(profile: profile, language: language) {
            throw UnavailableError(reason: reason)
        }
        guard let allergies = Self.allergies(in: profile),
              let (tag, templates) = AllergyTemplates.bundled?.language(for: language) else {
            throw UnavailableError(reason: .unsupportedLanguage(language))
        }
        let key = Key(language: tag, homeLanguage: profile.homeLanguage, allergies: allergies)
        if let cached = cards[key] { return cached }

        let chips = allergies.filter { $0.id != .custom }
        let customs = allergies.filter { $0.id == .custom }

        var lines: [AllergyShowCard.Line] = chips.compactMap { allergy in
            guard let allergen = templates.allergen(allergy.id) else { return nil }
            let text = allergen.text(for: allergy.severity)
            return AllergyShowCard.Line(
                id: "\(allergy.id.rawValue)-\(allergy.severity.rawValue)",
                allergenId: allergy.id,
                local: text.local,
                home: text.home,
                severity: allergy.severity,
                severityLocal: templates.severityLabel(allergy.severity)?.local
            )
        }
        let templateCard = Self.assemble(language: tag, templates: templates, lines: lines, hasFreeText: false)

        if !customs.isEmpty {
            let request = AllergyCardRequest(language: tag, homeLanguage: profile.homeLanguage, allergies: customs)
            let response: AllergyCardResponse
            do {
                response = try await freeTextCard(request, api: api)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
                throw FreeTextFailure(
                    labels: customs.compactMap(\.label),
                    message: message,
                    partial: lines.isEmpty ? nil : templateCard
                )
            }
            lines += response.items.enumerated().map { index, item in
                // The profile's severity is the truth. One item per typed-in
                // allergen comes back in order; if the server's differs, show
                // the stricter of the two, never a milder one.
                let requested = response.items.count == customs.count ? customs[index].severity : nil
                let severity = requested.map { Self.stricter($0, item.severity) } ?? item.severity
                if let requested, requested != item.severity {
                    RyokoLog.show.error("Allergy card: server wrote \(item.severity.rawValue, privacy: .public) for a \(requested.rawValue, privacy: .public) allergy; showing \(severity.rawValue, privacy: .public)")
                }
                return AllergyShowCard.Line(
                    id: "custom-\(index)-\(severity.rawValue)",
                    allergenId: .custom,
                    local: item.local,
                    home: item.home,
                    severity: severity,
                    severityLocal: templates.severityLabel(severity)?.local
                )
            }
        }

        let card = Self.assemble(language: tag, templates: templates, lines: lines, hasFreeText: !customs.isEmpty)
        cards[key] = card
        return card
    }

    private static let severityRank: [Severity: Int] = [.lifeThreatening: 0, .serious: 1, .mild: 2]

    private static func stricter(_ a: Severity, _ b: Severity) -> Severity {
        (severityRank[a] ?? 3) <= (severityRank[b] ?? 3) ? a : b
    }

    /// Title and request from the templates; the most serious lines first.
    private static func assemble(
        language: String,
        templates: AllergyTemplates.Language,
        lines: [AllergyShowCard.Line],
        hasFreeText: Bool
    ) -> AllergyShowCard {
        let rank = severityRank
        let sorted = lines.enumerated()
            .sorted { (rank[$0.element.severity] ?? 3, $0.offset) < (rank[$1.element.severity] ?? 3, $1.offset) }
            .map(\.element)
        return AllergyShowCard(
            language: language,
            titleLocal: templates.title.local,
            titleHome: templates.title.home,
            lines: sorted,
            requestLocal: templates.request.local,
            requestHome: templates.request.home,
            requestRomanization: templates.requestRomanization,
            reviewed: templates.reviewed && !hasFreeText
        )
    }

    /// The free-text lines: from disk if this exact request was answered before,
    /// otherwise from the server (and then saved).
    private func freeTextCard(_ request: AllergyCardRequest, api: any RyokoAPI) async throws -> AllergyCardResponse {
        let key = Self.freeTextKey(request)
        if let saved = freeText[key] { return saved }
        let response = try await api.allergyCard(request)
        freeText[key] = response
        saveFreeText()
        RyokoLog.show.info("Allergy card: \(response.items.count) free-text line(s) for \(request.language, privacy: .public)")
        return response
    }

    // MARK: Cache keys

    /// (language, home language, allergen and severity pairs). Order-independent.
    private struct Key: Hashable {
        var language: String
        var homeLanguage: String
        var pairs: [String]

        init(language: String, homeLanguage: String, allergies: [Allergy]) {
            self.language = language
            self.homeLanguage = homeLanguage
            pairs = allergies.map(AllergyCardStore.pairKey).sorted()
        }
    }

    nonisolated private static func pairKey(_ allergy: Allergy) -> String {
        let label = allergy.id == .custom
            ? ":" + (allergy.label ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            : ""
        return "\(allergy.id.rawValue)\(label)=\(allergy.severity.rawValue)"
    }

    private static func freeTextKey(_ request: AllergyCardRequest) -> String {
        ([request.language, request.homeLanguage] + request.allergies.map(pairKey).sorted()).joined(separator: "|")
    }

    // MARK: Storage

    /// `Caches/Ryoko/allergy-cards.json`: free-text answers by request key.
    static var defaultFileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appending(path: "Ryoko", directoryHint: .isDirectory).appending(path: "allergy-cards.json")
    }

    private static func loadFreeText(from url: URL?) -> [String: AllergyCardResponse] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: AllergyCardResponse].self, from: data)) ?? [:]
    }

    private func saveFreeText() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(freeText).write(to: fileURL, options: .atomic)
        } catch {
            RyokoLog.show.error("Couldn't save free-text allergy lines: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension String {
    /// "peanuts" → "Peanuts".
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
