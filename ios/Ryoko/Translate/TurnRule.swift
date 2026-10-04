import Foundation

// Translate's turns (design §4.8). Pure and Foundation only: the app and the
// Mac harness (`TurnRuleCheck.swift`) run the same code.

/// Who said a turn, worked out from its language.
nonisolated enum TurnSpeaker: String, Hashable, Sendable {
    case me
    case them
}

/// How turns change hands (design §4.8, #68).
nonisolated enum TurnMode: String, Hashable, Sendable {
    /// You say who's speaking by tapping their language. Everything heard goes
    /// into that person's turn until you tap the other language. The default.
    case manual
    /// The turn rule decides from the language Soniox hears.
    case automatic
}

/// How a turn was entered. Typed turns are tier 2 (Type mode).
nonisolated enum TurnSource: String, Hashable, Sendable {
    case voice
    case typed
}

/// One turn of the conversation: what someone said and its translation.
nonisolated struct Turn: Identifiable, Hashable, Sendable {
    /// How a turn ended.
    nonisolated enum Close: String, Hashable, Sendable {
        /// Soniox's `<end>`: the speaker paused.
        case endpoint
        /// The other language took over (the turn rule).
        case languageSwitch
        /// You tapped the other language (manual turns).
        case handOver
        /// The session stopped.
        case sessionEnd
        /// Typed in Type mode and added with Done (tier 2).
        case typed
    }

    let id: Int
    var speaker: TurnSpeaker
    /// Soniox code of what was said, e.g. `zh`.
    var language: String
    /// BCP-47 tags for display (`LocalText`): what was said, and its translation.
    var originalTag: String
    var translationTag: String
    /// As Soniox sent it (English words carry a leading space).
    var rawOriginal: String
    var rawTranslation: String
    var source: TurnSource = .voice
    var edited: Bool = false
    /// nil while the turn is open. Translations can still arrive after it closes.
    var closedBy: Close?

    var original: String { rawOriginal.trimmingCharacters(in: .whitespacesAndNewlines) }
    var translation: String { rawTranslation.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isClosed: Bool { closedBy != nil }

    /// Whether you can edit it (design §4.8): your own words, once the turn is
    /// over. Their words, and the translation field, aren't editable.
    var isEditable: Bool { speaker == .me && isClosed && !original.isEmpty }

    /// A turn typed in Type mode (tier 2): your words in your language, and
    /// their translation from `POST /v1/translate`. It's closed as it's added.
    static func typed(id: Int, pair: TranslatePair, text: String, translation: String) -> Turn {
        Turn(
            id: id,
            speaker: .me,
            language: pair.home.sonioxCode,
            originalTag: pair.home.tag,
            translationTag: pair.other.tag,
            rawOriginal: text,
            rawTranslation: translation,
            source: .typed,
            closedBy: .typed
        )
    }

    /// This turn with your words replaced, and the new translation (an edit).
    /// It keeps its id, speaker, languages and source, and is marked edited.
    func edited(original: String, translation: String) -> Turn {
        var turn = self
        turn.rawOriginal = original
        turn.rawTranslation = translation
        turn.edited = true
        return turn
    }
}

/// Type mode's text field rules (tier 2). Pure, for the harness.
nonisolated enum TypedText {
    /// The server takes at most this many characters (`TRANSLATE_MAX_CHARS`).
    static let maxCharacters = 500

    /// The field's text after a change. The field grows to several lines, but
    /// the return key means Done: a newline ends the text instead of being
    /// kept. Text past the limit is cut off.
    static func accept(_ raw: String) -> (text: String, submitted: Bool) {
        let submitted = raw.contains(where: \.isNewline)
        let text = submitted ? String(raw.filter { !$0.isNewline }) : raw
        return (String(text.prefix(maxCharacters)), submitted)
    }

    /// What gets translated, or nil when there's nothing to say.
    static func request(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Translate's turns across sessions (design §4.8): what History lists and the
/// panes show, plus typed turns and edits (tier 2). Pure, so the Mac harness
/// checks it with the turn rule.
nonisolated struct TurnLog: Sendable {
    /// Closed turns: earlier sessions' and typed ones, oldest first.
    private(set) var turns: [Turn] = []
    /// A turn the panes keep showing instead of the latest (the one you just
    /// edited from History). Cleared by the next new turn.
    private(set) var focusedId: Int?

    /// The id for the next turn, typed or spoken.
    var nextId: Int { (turns.map(\.id).max() ?? 0) + 1 }

    /// The focused turn, if any.
    var focused: Turn? { focusedId.flatMap { id in turns.first { $0.id == id } } }

    /// Adds a session's turns when it ends.
    mutating func archive(_ sessionTurns: [Turn]) {
        guard !sessionTurns.isEmpty else { return }
        turns += sessionTurns
        focusedId = nil
    }

    /// Adds a typed turn and returns it.
    @discardableResult
    mutating func addTyped(pair: TranslatePair, text: String, translation: String) -> Turn {
        let turn = Turn.typed(id: nextId, pair: pair, text: text, translation: translation)
        turns.append(turn)
        focusedId = nil
        return turn
    }

    /// Replaces your words in turn `id`. Returns false (and changes nothing)
    /// when there's no such turn or it isn't yours to edit.
    @discardableResult
    mutating func edit(id: Int, original: String, translation: String) -> Bool {
        guard let index = turns.firstIndex(where: { $0.id == id }), turns[index].isEditable else { return false }
        turns[index] = turns[index].edited(original: original, translation: translation)
        // The latest turn is on screen anyway; an older one stays there until the next turn.
        focusedId = index == turns.indices.last ? nil : id
        return true
    }

    /// Your most recent turn you can edit.
    var latestEditable: Turn? { turns.last(where: \.isEditable) }
}

/// The thresholds of the turn rule.
nonisolated struct TurnRule: Hashable, Sendable {
    /// Final tokens with a letter or digit in the other language that start a new turn.
    var minTokens = 2
    /// Or this many CJK characters (Chinese and Japanese tokens are often one character).
    var minCJK = 2

    /// Whether `tokens` (final, in the other language) are enough for a new turn.
    func startsTurn(_ tokens: [SonioxToken]) -> Bool {
        let wordy = tokens.filter { Self.isWordy($0.text) }.count
        let cjk = tokens.reduce(0) { $0 + Self.cjkCount($1.text) }
        return wordy >= minTokens || cjk >= minCJK
    }

    /// Whether a token has a letter or digit (not just spaces or punctuation).
    static func isWordy(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Han, kana and hangul characters in `text`.
    static func cjkCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // hiragana, katakana
                 0x3400...0x4DBF, // CJK extension A
                 0x4E00...0x9FFF, // CJK unified ideographs
                 0xF900...0xFAFF, // CJK compatibility ideographs
                 0xAC00...0xD7AF, // hangul syllables
                 0x20000...0x2FA1F: // CJK extensions B and later
                count + 1
            default:
                count
            }
        }
    }
}

/// Builds turns from Soniox responses (design §4.8).
///
/// **Manual turns** (the default, #68):
///
/// - Everything heard goes into the current speaker's turn, whatever language
///   Soniox tags it with. `<end>` doesn't close it: a pause isn't a new turn.
/// - `handOver(to:)` starts the other person's turn. When something heard may
///   still belong to the current speaker, Soniox is asked to finalize first and
///   the turn changes hands at its `<fin>` (or `completeHandOver(force:)`
///   after a timeout), so the last words stay with the right person.
/// - A translated token attaches to the turn that last heard words in its
///   `source_language`.
/// - The panes keep the previous turn until the new speaker's words arrive.
///
/// **Automatic turns:**
///
/// - A new turn starts when at least 2 final tokens (or 2 CJK characters)
///   arrive in the other language. Fewer than that is a false flip: those
///   tokens join the open turn when its language comes back, or at `<end>`.
/// - `<end>` commits (closes) the open turn. The next final token opens a new one.
/// - A translated token attaches to the most recent turn whose language is the
///   token's `source_language`, even after that turn closed.
/// - The panes never clear before the new turn has text: `display` keeps the
///   latest turn until a newer one has some.
///
/// Non-final tokens only affect `display`; the rule runs on final tokens.
nonisolated struct TurnBuilder: Sendable {
    let pair: TranslatePair
    let rule: TurnRule
    let mode: TurnMode

    /// Every turn of this session, oldest first.
    private(set) var turns: [Turn] = []
    /// Final tokens in the other language that haven't reached the threshold yet.
    private(set) var pending: [SonioxToken] = []
    /// The latest response's non-final tokens.
    private(set) var tail: [SonioxToken] = []

    // Counters for the harness and logs.
    private(set) var absorbedFlips = 0
    private(set) var orphanTranslations = 0
    private(set) var lateTranslationTokens = 0
    /// Manual turns: translations of words Soniox heard as the other language.
    private(set) var strayTranslationTokens = 0

    /// Manual turns: who's speaking. Everything heard goes into their turn.
    private(set) var speaker: TurnSpeaker
    /// Manual turns: who takes over once Soniox has finalized what came before.
    private(set) var handOverTo: TurnSpeaker?
    /// Manual turns: finalize requests whose `<fin>` hasn't come back yet.
    private var awaitedFins = 0
    /// Manual turns: final words since the speaker's own language, in the other one.
    private var otherLanguageRun: [SonioxToken] = []
    /// Manual turns: the turn that last heard words in each language.
    private var lastHeard: [String: Int] = [:]

    private var openIndex: Int?
    private var nextId: Int

    /// - Parameters:
    ///   - mode: manual (you say who's speaking) or automatic (the turn rule).
    ///   - speaker: manual turns: who speaks first.
    ///   - firstId: ids continue across sessions, so history rows stay unique.
    init(pair: TranslatePair, rule: TurnRule = TurnRule(), mode: TurnMode = .automatic, speaker: TurnSpeaker = .me, firstId: Int = 1) {
        self.pair = pair
        self.rule = rule
        self.mode = mode
        self.speaker = speaker
        nextId = firstId
    }

    /// Manual turns: who the controls show as speaking (the one taking over, if
    /// a hand-over is waiting for Soniox).
    var activeSpeaker: TurnSpeaker { handOverTo ?? speaker }

    /// Manual turns: Soniox keeps hearing the other language in the open turn
    /// (4 words or 4 CJK characters in a row). Maybe the other person is
    /// talking and nobody switched: the controls suggest it.
    var hearsOtherSpeaker: Bool {
        guard mode == .manual, handOverTo == nil, openIndex != nil else { return false }
        return TurnRule(minTokens: 4, minCJK: 4).startsTurn(otherLanguageRun)
    }

    // MARK: Hand-over (manual turns)

    /// Hands the turn to `next`. Returns true when Soniox should finalize
    /// first (`{"type":"finalize"}`), because words heard so far may still
    /// belong to the current speaker; the turn then changes hands at `<fin>`.
    /// Tapping the current speaker again before that cancels the hand-over.
    mutating func handOver(to next: TurnSpeaker) -> Bool {
        guard mode == .manual, next != activeSpeaker else { return false }
        if handOverTo != nil {
            handOverTo = nil // back to the current speaker before `<fin>` came
            return false
        }
        let hasLiveWords = tail.contains { $0.isOriginal && TurnRule.isWordy($0.text) }
        guard openIndex != nil || hasLiveWords else {
            speaker = next
            otherLanguageRun = []
            return false
        }
        handOverTo = next
        awaitedFins += 1
        return true
    }

    /// The turn changes hands: at `<fin>`, or with `force` when it didn't come in time.
    mutating func completeHandOver(force: Bool = false) {
        if force {
            awaitedFins = 0
        } else {
            awaitedFins = max(0, awaitedFins - 1)
            guard awaitedFins == 0 else { return }
        }
        guard let next = handOverTo else { return }
        handOverTo = nil
        // Without `<fin>`, live words could be either person's; they go to
        // whoever speaks once Soniox finalizes them.
        close(.handOver)
        speaker = next
        otherLanguageRun = []
    }

    /// The id the next turn will get.
    var upcomingId: Int { nextId }

    /// The open turn, if any.
    var openTurn: Turn? { openIndex.map { turns[$0] } }

    // MARK: Input

    /// Applies one Soniox response: its final tokens in order, and its
    /// non-final tokens as the new tail.
    mutating func apply(_ tokens: [SonioxToken]) {
        var newTail: [SonioxToken] = []
        for token in tokens {
            if token.isFinal {
                applyFinal(token)
            } else if !token.isMarker {
                newTail.append(token)
            }
        }
        tail = newTail
    }

    /// The session ended: whatever was still non-final counts as said, false
    /// flips go back into the open turn, and the open turn closes.
    mutating func endSession() {
        let leftover = tail
        tail = []
        for var token in leftover {
            token.isFinal = true
            applyFinal(token)
        }
        absorbPending()
        close(.sessionEnd)
        if let next = handOverTo {
            speaker = next
            handOverTo = nil
        }
        awaitedFins = 0
    }

    private mutating func applyFinal(_ token: SonioxToken) {
        if token.isEndpoint {
            // Manual turns: a pause isn't a new turn.
            guard mode == .automatic else { return }
            absorbPending()
            close(.endpoint)
            return
        }
        if token.text == SonioxToken.finalizeMarker {
            completeHandOver()
            return
        }
        if token.isTranslation {
            attachTranslation(token)
            return
        }
        applyOriginal(token)
    }

    private mutating func applyOriginal(_ token: SonioxToken) {
        if mode == .manual {
            applyLocked(token)
            return
        }
        let wordy = TurnRule.isWordy(token.text)
        guard let open = openIndex else {
            if wordy {
                startTurn(language: language(of: token, fallback: nil), tokens: [token])
            } else if let lastIndex = turns.indices.last,
                      turns[lastIndex].language == token.language,
                      !token.text.trimmingCharacters(in: .whitespaces).isEmpty {
                // Punctuation right after `<end>` still belongs to the turn it ends.
                turns[lastIndex].rawOriginal += token.text
            }
            return
        }

        let openLanguage = turns[open].language
        let tokenLanguage = language(of: token, fallback: openLanguage)
        if tokenLanguage == openLanguage {
            absorbPending()
            turns[open].rawOriginal += token.text
            return
        }

        // The other language.
        if !wordy && pending.isEmpty {
            // Spaces and punctuation don't start anything.
            turns[open].rawOriginal += token.text
            return
        }
        pending.append(token)
        let sameLanguage = pending.filter { language(of: $0, fallback: openLanguage) == tokenLanguage }
        if rule.startsTurn(sameLanguage) {
            let tokens = pending
            pending = []
            close(.languageSwitch)
            startTurn(language: tokenLanguage, tokens: tokens)
        }
    }

    /// Manual turns: the word goes into the current speaker's turn.
    private mutating func applyLocked(_ token: SonioxToken) {
        let wordy = TurnRule.isWordy(token.text)
        let ownLanguage = code(for: speaker)
        if openIndex == nil {
            // Spaces and punctuation don't open a turn.
            guard wordy else { return }
            startTurn(language: ownLanguage, tokens: [token])
        } else if let open = openIndex {
            turns[open].rawOriginal += token.text
        }
        guard let open = openIndex else { return }
        let heard = language(of: token, fallback: ownLanguage)
        lastHeard[heard] = open
        if wordy {
            if heard == ownLanguage {
                otherLanguageRun = []
            } else {
                otherLanguageRun.append(token)
            }
        }
    }

    private func code(for speaker: TurnSpeaker) -> String {
        speaker == .me ? pair.home.sonioxCode : pair.other.sonioxCode
    }

    /// Manual turns: where a translation from `source` goes.
    private func lockedIndex(forSource source: String) -> Int? {
        lastHeard[source] ?? turns.lastIndex { $0.language == source }
    }

    private mutating func attachTranslation(_ token: SonioxToken) {
        if mode == .manual {
            guard let source = token.sourceLanguage, let index = lockedIndex(forSource: source) else {
                orphanTranslations += 1
                return
            }
            if turns[index].language != source { strayTranslationTokens += 1 }
            if turns[index].isClosed || index != turns.indices.last { lateTranslationTokens += 1 }
            turns[index].rawTranslation += token.text
            return
        }
        guard let source = token.sourceLanguage,
              let index = turns.lastIndex(where: { $0.language == source }) else {
            orphanTranslations += 1
            return
        }
        if turns[index].isClosed || index != turns.indices.last {
            lateTranslationTokens += 1
        }
        turns[index].rawTranslation += token.text
    }

    /// The language a token counts as. A language outside the pair (Soniox
    /// guessing a third language) counts as the open turn's, so it never
    /// starts a turn of its own.
    private func language(of token: SonioxToken, fallback: String?) -> String {
        if let code = token.language, pair.language(forSoniox: code) != nil { return code }
        return fallback ?? token.language ?? pair.other.sonioxCode
    }

    private mutating func absorbPending() {
        guard !pending.isEmpty, let open = openIndex else {
            pending = []
            return
        }
        absorbedFlips += 1
        turns[open].rawOriginal += pending.map(\.text).joined()
        pending = []
    }

    private mutating func close(_ reason: Turn.Close) {
        guard let open = openIndex else { return }
        turns[open].closedBy = reason
        openIndex = nil
    }

    private mutating func startTurn(language: String, tokens: [SonioxToken]) {
        turns.append(makeTurn(id: nextId, language: language, original: tokens.map(\.text).joined()))
        nextId += 1
        openIndex = turns.indices.last
    }

    private func makeTurn(id: Int, language: String, original: String) -> Turn {
        let isHome = language == pair.home.sonioxCode
        let originalTag = pair.language(forSoniox: language)?.tag ?? language
        return Turn(
            id: id,
            speaker: isHome ? .me : .them,
            language: language,
            originalTag: originalTag,
            translationTag: isHome ? pair.other.tag : pair.home.tag,
            rawOriginal: original,
            rawTranslation: ""
        )
    }

    // MARK: Output

    /// The turn the panes show: the latest turn, with the live (non-final)
    /// words that continue it. Before the first final token, the live words
    /// alone. nil until anyone has said anything.
    var display: Turn? {
        if mode == .manual { return lockedDisplay }
        let liveOriginals = tail.filter(\.isOriginal)
        guard var latest = turns.last else {
            guard let first = liveOriginals.first(where: { TurnRule.isWordy($0.text) }) else { return nil }
            let language = language(of: first, fallback: nil)
            var provisional = makeTurn(
                id: nextId,
                language: language,
                original: liveOriginals.map(\.text).joined()
            )
            provisional.rawTranslation = liveTranslation(from: language)
            return provisional
        }
        if !latest.isClosed && pending.isEmpty {
            // Only the live words that continue the open turn's language.
            let continuing = liveOriginals.prefix { language(of: $0, fallback: latest.language) == latest.language }
            latest.rawOriginal += continuing.map(\.text).joined()
        }
        latest.rawTranslation += liveTranslation(from: latest.language)
        return latest
    }

    /// Manual turns: the open turn with every live word; before it has a final
    /// word, the live words alone as the speaker's; otherwise the latest turn.
    private var lockedDisplay: Turn? {
        let liveOriginals = tail.filter(\.isOriginal)
        if let open = openIndex {
            var turn = turns[open]
            turn.rawOriginal += liveOriginals.map(\.text).joined()
            turn.rawTranslation += lockedLiveTranslation(for: open)
            return turn
        }
        if liveOriginals.contains(where: { TurnRule.isWordy($0.text) }) {
            let language = code(for: speaker)
            var provisional = makeTurn(id: nextId, language: language, original: liveOriginals.map(\.text).joined())
            provisional.rawTranslation = liveTranslation(from: language)
            return provisional
        }
        guard var latest = turns.last else { return nil }
        latest.rawTranslation += lockedLiveTranslation(for: turns.count - 1)
        return latest
    }

    private func lockedLiveTranslation(for index: Int) -> String {
        tail.filter { token in
            guard token.isTranslation, let source = token.sourceLanguage else { return false }
            return (lastHeard[source] ?? index) == index
        }
        .map(\.text).joined()
    }

    /// Every turn for History, the latest with its live words.
    var history: [Turn] {
        guard let shown = display else { return turns }
        if let last = turns.last, last.id == shown.id {
            return Array(turns.dropLast()) + [shown]
        }
        return turns + [shown]
    }

    private func liveTranslation(from language: String) -> String {
        tail.filter { $0.isTranslation && $0.sourceLanguage == language }.map(\.text).joined()
    }
}
