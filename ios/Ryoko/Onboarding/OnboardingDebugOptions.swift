#if DEBUG
import Foundation
import os

/// DEBUG launch arguments for the survey and Me's editors (T2.3). There's no
/// tap automation, so screens are driven from the command line:
///
///     xcrun simctl launch <udid> com.danielou.ryoko \
///       -RyokoOnboarding 1 -RyokoOnboardingSample 1 -RyokoOnboardingPage 4
///
/// - `-RyokoOnboarding 1|0`: always / never show the survey at launch. Unset,
///   it shows on first launch only, and never when other `-Ryoko…` arguments
///   script the launch (so existing screenshot flows go straight to their screen).
/// - `-RyokoOnboardingPage <1-7 or name>`: open the survey at that page.
/// - `-RyokoOnboardingSample 1`: start from sample answers instead of a blank survey.
/// - `-RyokoOnboardingSearch "<query>"`: type a query on the home base page.
/// - `-RyokoOnboardingPick 1`: also pick the first suggestion for that query.
/// - `-RyokoOnboardingMapPicker open|use`: open Pick on map from the home base
///   page (or Me's editor); `use` then takes the spot under the pin.
/// - `-RyokoOnboardingAutoRun 1`: go through every page by itself, through the
///   same Continue and Skip actions as the buttons (Skip for the pages listed in
///   `-RyokoOnboardingSkip 3,6`), pick the first home base suggestion, and
///   finish. The saved profile is printed and is in
///   `Application Support/Ryoko/profile.json`.
/// - `-RyokoMeEdit <page name>|redo`: Me opens that page's editor, or the
///   survey, at launch. Use with `-RyokoInitialTab me`.
/// - `-RyokoMeEditSample 1`: that editor then takes the sample answers, as if
///   tapped in, so the saved profile and its version change.
///
/// Page names: origin, languages, diet, allergies, usual, thisOrThat, homeBase.
enum OnboardingDebugOptions {
    private static var defaults: UserDefaults { .standard }

    /// `-RyokoOnboarding 1` or `0`; nil when not given.
    static var forced: Bool? {
        defaults.object(forKey: "RyokoOnboarding") == nil ? nil : defaults.bool(forKey: "RyokoOnboarding")
    }

    /// Launched with other `-Ryoko…` arguments (a scripted screenshot run).
    static var isScriptedLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Ryoko") && !$0.hasPrefix("-RyokoOnboarding") }
    }

    static var startPage: SurveyPage? {
        defaults.string(forKey: "RyokoOnboardingPage").flatMap(page(named:))
    }

    static var usesSample: Bool { defaults.bool(forKey: "RyokoOnboardingSample") }

    static var homeBaseQuery: String? {
        if let query = defaults.string(forKey: "RyokoOnboardingSearch"), !query.isEmpty { return query }
        return autoRun ? "Park Hyatt Tokyo" : nil
    }

    static var picksHomeBase: Bool { autoRun || defaults.bool(forKey: "RyokoOnboardingPick") }

    /// `-RyokoOnboardingMapPicker open|use`: the home base page opens Pick on
    /// map, and with `use` also takes the spot under the pin.
    static var mapPickerAction: String? { defaults.string(forKey: "RyokoOnboardingMapPicker") }

    static var autoRun: Bool { defaults.bool(forKey: "RyokoOnboardingAutoRun") }

    static var skippedPages: Set<SurveyPage> {
        let raw = defaults.string(forKey: "RyokoOnboardingSkip") ?? ""
        return Set(raw.split(separator: ",").compactMap { page(named: String($0)) })
    }

    /// `-RyokoMeEdit`: a page, or nil for `redo` and when not given.
    static var meEditorPage: SurveyPage? {
        defaults.string(forKey: "RyokoMeEdit").flatMap(page(named:))
    }

    static var meRedoesSurvey: Bool { defaults.string(forKey: "RyokoMeEdit") == "redo" }

    /// `-RyokoMeEditSample 1`: the open editor takes the sample answers after a
    /// moment, through its own change handler (the path a tap takes).
    static var meEditAppliesSample: Bool { defaults.bool(forKey: "RyokoMeEditSample") }

    /// A page by number (`4`) or name (`allergies`).
    static func page(named name: String) -> SurveyPage? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if let number = Int(name) { return SurveyPage(rawValue: number) }
        let names: [String: SurveyPage] = [
            "origin": .origin, "languages": .languages, "diet": .diet, "allergies": .allergies,
            "usual": .usual, "thisOrThat": .thisOrThat, "homeBase": .homeBase,
        ]
        return names[name]
    }

    /// Sample answers for screenshots and the auto run: a traveller unlike the
    /// seed, so every page shows a selection.
    static var sampleDraft: SurveyDraft {
        SurveyDraft(
            nationality: "AU",
            homeLanguage: "en",
            spokenLanguages: ["en", "fr"],
            diet: [.noPork],
            dietNotes: "No raw onion",
            allergies: [
                Allergy(id: .sesame, label: nil, severity: .lifeThreatening),
                Allergy(id: .crustaceanMollusc, label: nil, severity: .mild),
                Allergy(id: .custom, label: "Kiwi", severity: .serious),
            ],
            foods: ["noodles", "dumplings", "Xiaolongbao"],
            drinks: ["milk tea", "coffee"],
            sweetness: 1,
            spice: 3,
            personality: Personality(rhythm: .earlyBird, food: .localFavourite, budget: nil, vibe: .lively),
            homeBase: nil
        )
    }

    /// Applies `-RyokoOnboardingPage` and runs `-RyokoOnboardingAutoRun`.
    @MainActor
    static func drive(_ model: SurveyModel) async {
        if let startPage { model.jump(to: startPage) }
        guard autoRun else { return }
        let skipped = skippedPages
        RyokoLog.onboarding.info("Auto run: skipping \(skipped.map(\.rawValue).sorted(), privacy: .public)")
        for page in SurveyPage.allCases where page.rawValue >= (startPage?.rawValue ?? 1) {
            try? await Task.sleep(for: .seconds(1.5))
            if page == .homeBase, !skipped.contains(page) {
                // The home base form types the query and picks the first suggestion.
                for _ in 0..<80 where model.draft.homeBase == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .seconds(2))
            }
            if skipped.contains(page) {
                model.skip(page)
            } else {
                model.answer(page)
            }
        }
    }

    /// Prints the saved profile (DEBUG only; it holds no secrets).
    static func logProfile(_ profile: Profile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(profile), let json = String(data: data, encoding: .utf8) else { return }
        print("RYOKO_PROFILE \(json)")
        RyokoLog.onboarding.info("Saved profile: \(json, privacy: .public)")
    }
}
#endif
