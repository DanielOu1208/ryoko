import Foundation

/// Whether a MapKit name is the place that was asked for (design §4.7: accept a
/// hit only if its name is similar to the requested name).
///
/// It compares words, not letters. Letter similarity let wrong places through:
/// "Kokoro Tea Shinjuku" matched "Kokoro Shinjuku Honten" (another business),
/// "Hanazono Shrine" matched "Hanazono Shrine Tori no Ichi" (a festival
/// listing) and "BEAMS Lumine Shinjuku" matched "Lumine Shinjuku 2" (the
/// building). Now:
///
/// - Every word of the requested name must be in the map's name. Only area
///   words ("Shinjuku", from the map item's own area) and branch words
///   ("Honten") may be missing.
/// - The map's name may add only qualifiers: area words, branch words, a kind
///   of place ("National Garden", "Cafe"), or anything in brackets
///   ("Starbucks (Nanjing West Road)").
/// - Chinese and Japanese names have no spaces, so one name must start with
///   the other and the rest be a branch ("喜茶静安店", "椿屋珈琲新宿本館"), or
///   they must be the same once a bracketed branch is set aside.
///
/// A miss only drops a pick; a wrong match puts Mimo's why on the wrong
/// place, so when in doubt this says no.
nonisolated enum PlaceNameMatch {
    /// Lowercased, without diacritics, full-width forms or punctuation:
    /// "Omoide Yokochō" → "omoideyokocho", "ＣＯＣＯ都可" → "coco都可".
    static func normalized(_ name: String) -> String {
        let folded = fold(name)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    /// 3: the same name. 2: every requested word is there, and the map's name
    /// adds only qualifiers. 1: the same, once area and branch words in the
    /// request are set aside ("Shinjuku Golden Gai" / "Golden Gai"), or a
    /// Chinese or Japanese name plus a branch. 0: not the place.
    ///
    /// - Parameter areaWords: words naming the area the place is in
    ///   (`areaWords(from:)`), which may qualify either name.
    static func score(_ candidate: String, against wanted: String?, areaWords: Set<String> = []) -> Int {
        guard let wanted else { return 0 }
        let a = normalized(candidate)
        let b = normalized(wanted)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 3 }
        if hasCJK(a) || hasCJK(b) { return cjkScore(candidate, wanted) }
        return wordScore(candidate, wanted, areaWords: areaWords)
    }

    /// Words from addresses and area names ("Shinjuku-ku, Tokyo", "Jing'an
    /// District, Shanghai") that may qualify a place's name: letters only, at
    /// least 3 of them ("shinjuku", "jingan").
    static func areaWords(from texts: [String?]) -> Set<String> {
        var result = Set<String>()
        for text in texts.compactMap(\.self) {
            for part in words(text) where part.count >= 3 && part.allSatisfy(\.isLetter) {
                result.insert(part)
            }
        }
        return result
    }

    // MARK: Words

    /// Branch and location qualifiers either name may carry ("Honten",
    /// "Higashiguchi-Shop", "South exit").
    static let branchWords: Set<String> = [
        "honten", "shiten", "honkan", "bekkan", "branch", "main", "annex", "annexe", "outlet", "flagship",
        "higashiguchi", "nishiguchi", "minamiguchi", "kitaguchi", "ekimae", "ekinaka", "exit",
        "east", "west", "south", "north", "the", "and", "of", "at",
    ]

    /// Kinds of place the map's name may add to a name ("Shinjuku Gyoen
    /// National Garden", "Blue Bottle Coffee Shinjuku Cafe").
    static let kindWords: Set<String> = [
        "cafe", "coffee", "kissa", "kissaten", "tea", "teahouse", "bar", "pub", "restaurant", "shokudo", "izakaya",
        "ramen", "sushi", "bakery", "patisserie", "shop", "store", "market", "park", "garden", "gardens", "national",
        "shrine", "shinto", "jinja", "jingu", "temple", "museum", "gallery", "hall", "center", "centre", "plaza", "building", "tower",
        "station", "hotel", "inn", "house", "kitchen", "dining", "bistro", "brewery", "books", "bookstore",
        "library", "square", "mall", "hostel", "lounge", "stand",
    ]

    /// Romanized words MapKit uses where Mimo translates ("Kohi Seibu" / "Coffee Seibu").
    static let sameWords: [String: String] = ["kohi": "coffee", "kohii": "coffee", "koohii": "coffee"]

    /// Folded words: apostrophes join ("Jing'an" → "jingan"); anything else
    /// that isn't a letter or digit splits, hyphens too ("Shinjuku-Shop").
    /// Hyphenated spellings of one word ("Fu-unji") still match whole names
    /// through `normalized`.
    static func words(_ name: String) -> [String] {
        fold(name)
            .replacingOccurrences(of: "['’‘`]", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { sameWords[$0] ?? $0 }
    }

    /// An area word, or one built on it ("nishishinjuku" on "shinjuku").
    private static func isArea(_ word: String, in area: Set<String>) -> Bool {
        area.contains(word) || area.contains { $0.count >= 5 && word.count > $0.count && word.contains($0) }
    }

    private static func wordScore(_ candidate: String, _ wanted: String, areaWords area: Set<String>) -> Int {
        let wantedBase = words(withoutBrackets(wanted))
        guard !wantedBase.isEmpty else { return 0 }
        let wantedAll = Set(words(wanted))
        let candidateAll = Set(words(candidate))

        // The map's name adds only qualifiers.
        let extras = words(withoutBrackets(candidate)).filter { !wantedAll.contains($0) }
        guard extras.allSatisfy({ isArea($0, in: area) || branchWords.contains($0) || kindWords.contains($0) }) else {
            return 0
        }
        let missing = wantedBase.filter { !candidateAll.contains($0) }
        if missing.isEmpty { return 2 }
        // Only area and branch words may be missing, and something distinctive
        // must still match: "Kokoro Tea Shinjuku" is not "Kokoro Shinjuku Honten".
        guard missing.allSatisfy({ isArea($0, in: area) || branchWords.contains($0) }) else { return 0 }
        let distinctive = wantedBase.filter {
            candidateAll.contains($0) && !isArea($0, in: area) && !branchWords.contains($0) && !kindWords.contains($0)
        }
        return distinctive.isEmpty ? 0 : 1
    }

    // MARK: Chinese and Japanese

    private static func cjkScore(_ candidate: String, _ wanted: String) -> Int {
        let a = normalized(withoutBrackets(candidate))
        let b = normalized(withoutBrackets(wanted))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        // "喜茶(静安嘉里中心店)" and "喜茶".
        if a == b { return 2 }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 2, long.hasPrefix(short) else { return 0 }
        let rest = long.dropFirst(short.count)
        // A branch: "静安店", "新宿本館". Not "酉の市" (an event) or "2" (another building).
        let isBranch = rest.count <= 10 && ["店", "館", "馆"].contains { rest.hasSuffix($0) }
        return isBranch ? 1 : 0
    }

    private static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }
    }

    // MARK: Helpers

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// The name without bracketed qualifiers: "Starbucks (Nanjing West Road)" → "Starbucks ".
    private static func withoutBrackets(_ name: String) -> String {
        name.replacingOccurrences(
            of: "[(（\\[【「〔][^)）\\]】」〕]*[)）\\]】」〕]",
            with: " ",
            options: .regularExpression
        )
    }
}

// MARK: - Check

// The cases below run on the Mac, with no simulator:
//
//   ROOT=$(git rev-parse --show-toplevel); OUT="$ROOT/ios/.build/place-name-check"; mkdir -p "$OUT"
//   xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
//     -D PLACE_NAME_MATCH_CHECK_MAIN -module-name PlaceNameCheck -o "$OUT/place-name-check" \
//     "$ROOT/ios/Ryoko/Map/PlaceNameMatch.swift" && "$OUT/place-name-check"
//
// It exits non-zero if any case fails.

#if DEBUG || PLACE_NAME_MATCH_CHECK_MAIN
nonisolated enum PlaceNameMatchCheck {
    struct Case {
        var candidate: String
        var wanted: String
        var area: [String] = ["Shinjuku, Tokyo, Japan"]
        var accept: Bool
    }

    static let cases: [Case] = [
        // Wrong places the old letter similarity accepted (review, 2026-10-03).
        Case(candidate: "Kokoro Shinjuku Honten", wanted: "Kokoro Tea Shinjuku", accept: false),
        Case(candidate: "Hanazono Shrine Tori no Ichi", wanted: "Hanazono Shrine", accept: false),
        Case(candidate: "Lumine Shinjuku 2", wanted: "BEAMS Lumine Shinjuku", accept: false),
        Case(candidate: "花園神社 酉の市", wanted: "花園神社", accept: false),
        Case(candidate: "ルミネ新宿2", wanted: "BEAMS ルミネ新宿", accept: false),
        Case(candidate: "Lumine Shinjuku", wanted: "BEAMS Lumine Shinjuku", accept: false),
        Case(candidate: "Gyoen Cafe", wanted: "Shinjuku Gyoen National Garden", accept: false),
        Case(candidate: "Kokoro", wanted: "Kokoro Tea", accept: false),
        Case(candidate: "Golden Gai Bar Albatross", wanted: "Shinjuku Golden Gai", accept: false),
        // A real miss, kept on purpose: the map adds a word Mimo left out.
        Case(candidate: "Coffee Aristocracy Edinburgh Shinjuku", wanted: "Coffee Edinburgh", accept: false),
        // The same place, named a little differently.
        Case(candidate: "Hanazono Shrine", wanted: "Hanazono Shrine", accept: true),
        // MapKit's own names in Shinjuku (English UI, 2026-10-03).
        Case(candidate: "HANAZONO Shinto shrine", wanted: "Hanazono Shrine", accept: true),
        Case(candidate: "Starbucks Coffee Lumine Shinjuku-Shop", wanted: "Starbucks Coffee Lumine Shinjuku", accept: true),
        Case(candidate: "Hoshino Coffee Shinjuku Higashiguchi-Shop", wanted: "Hoshino Coffee Shinjuku", accept: true),
        Case(candidate: "Tsubakiya Coffee Shinjuku Tea House", wanted: "Tsubakiya Coffee Shinjuku", accept: true),
        Case(candidate: "Kohi Seibu Nishishinjuku-Shop", wanted: "Coffee Seibu", accept: true),
        Case(candidate: "Tajimaya Coffee-Shop Shinjuku South Exit-Shop", wanted: "Tajimaya Coffee", accept: true),
        Case(candidate: "Fuunji", wanted: "Fu-unji", accept: true),
        Case(candidate: "Omoide Yokochō", wanted: "Omoide Yokocho", accept: true),
        Case(candidate: "Shinjuku Gyoen National Garden", wanted: "Shinjuku Gyoen", accept: true),
        Case(candidate: "Blue Bottle Coffee Shinjuku Cafe", wanted: "Blue Bottle Coffee", accept: true),
        Case(candidate: "Golden Gai", wanted: "Shinjuku Golden Gai", accept: true),
        Case(candidate: "Kokoro Shinjuku Honten", wanted: "Kokoro", accept: true),
        Case(candidate: "Starbucks (Nanjing West Road)", wanted: "Starbucks", area: ["Jing'an District, Shanghai, China"], accept: true),
        Case(candidate: "Jing'an Temple", wanted: "Jingan Temple", area: ["Jing'an, Shanghai, China"], accept: true),
        Case(candidate: "喜茶(静安嘉里中心店)", wanted: "喜茶", accept: true),
        Case(candidate: "喜茶静安店", wanted: "喜茶", accept: true),
        Case(candidate: "椿屋珈琲 新宿本館", wanted: "椿屋珈琲", accept: true),
        Case(candidate: "CoCo都可(南京西路店)", wanted: "CoCo都可", accept: true),
    ]

    /// Failure lines; empty when every case passes.
    static func run() -> [String] {
        cases.compactMap { item in
            let area = PlaceNameMatch.areaWords(from: item.area)
            let score = PlaceNameMatch.score(item.candidate, against: item.wanted, areaWords: area)
            guard (score > 0) != item.accept else { return nil }
            return "\(item.accept ? "should match" : "should not match"): \"\(item.wanted)\" → \"\(item.candidate)\" (score \(score))"
        }
    }
}
#endif

#if PLACE_NAME_MATCH_CHECK_MAIN
@main
struct PlaceNameCheckMain {
    static func main() {
        let failures = PlaceNameMatchCheck.run()
        for failure in failures { print("FAIL \(failure)") }
        print("\(PlaceNameMatchCheck.cases.count - failures.count)/\(PlaceNameMatchCheck.cases.count) cases pass")
        if !failures.isEmpty { exit(1) }
    }
}
#endif
