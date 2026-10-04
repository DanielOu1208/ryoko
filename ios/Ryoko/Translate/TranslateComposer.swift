import Foundation
import Observation
import os

/// Type mode and the turn editor (design §4.8, T2.4): the text you type, and
/// its translation from `POST /v1/translate`.
///
/// - The translation updates on Done, and on typing pauses of about 500 ms.
/// - Each new keystroke cancels the pending request (and the one in flight,
///   which stops the server's generation too). A late answer for older text is
///   never shown.
/// - The situation goes along, so the wording fits the place.
@MainActor
@Observable
final class TranslateComposer {
    /// What the composer is for.
    enum Purpose: Equatable {
        /// Type mode: a new turn in your language.
        case typing(TranslatePair)
        /// Editing your words in an existing turn.
        case editing(Turn)
    }

    /// How long typing has to pause before the translation updates.
    static let pause: Duration = .milliseconds(500)

    /// nil while closed.
    private(set) var purpose: Purpose?
    /// The field's text.
    private(set) var text = ""
    /// The latest translation, and the text it's for. It stays (dimmed) while
    /// a newer one loads, so the preview doesn't flicker.
    private(set) var translation: String?
    private(set) var translatedText: String?
    /// A request is going.
    private(set) var isTranslating = false
    /// Why the last request failed, in words that are safe to show.
    private(set) var failure: String?
    /// Done is waiting for the translation.
    private(set) var isFinishing = false

    var isOpen: Bool { purpose != nil }

    /// The language you type in, and the one it goes to.
    var source: PairLanguage? {
        switch purpose {
        case .typing(let pair): pair.home
        case .editing(let turn): PairLanguage(tag: turn.originalTag)
        case nil: nil
        }
    }

    var target: PairLanguage? {
        switch purpose {
        case .typing(let pair): pair.other
        case .editing(let turn): PairLanguage(tag: turn.translationTag)
        case nil: nil
        }
    }

    /// Whether the shown translation matches the text as it is now.
    var isCurrent: Bool {
        guard let request = TypedText.request(text) else { return true }
        return translatedText == request && translation != nil
    }

    @ObservationIgnored private var api: (any RyokoAPI)?
    @ObservationIgnored private var situation: () -> Situation? = { nil }
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Goes up with each request; an answer for an older one is dropped.
    @ObservationIgnored private var generation = 0

    // MARK: Open and close

    /// Opens Type mode for `pair`.
    func openTyping(pair: TranslatePair, api: any RyokoAPI, situation: @escaping () -> Situation?) {
        reset()
        self.api = api
        self.situation = situation
        purpose = .typing(pair)
    }

    /// Opens the editor on your turn, with its words and translation.
    func openEditing(_ turn: Turn, api: any RyokoAPI, situation: @escaping () -> Situation?) {
        reset()
        self.api = api
        self.situation = situation
        purpose = .editing(turn)
        text = turn.original
        translation = turn.translation.isEmpty ? nil : turn.translation
        translatedText = turn.original
    }

    func close() {
        reset()
        purpose = nil
    }

    private func reset() {
        pending?.cancel()
        pending = nil
        generation += 1
        text = ""
        translation = nil
        translatedText = nil
        isTranslating = false
        failure = nil
        isFinishing = false
    }

    // MARK: Typing

    /// The field changed. Returns true when the change was the return key,
    /// which means Done.
    @discardableResult
    func update(_ raw: String) -> Bool {
        let accepted = TypedText.accept(raw)
        if accepted.text != text {
            text = accepted.text
            scheduleTranslation()
        }
        return accepted.submitted
    }

    /// Translates after a pause in typing. Cancels what was pending.
    private func scheduleTranslation() {
        pending?.cancel()
        failure = nil
        guard let request = TypedText.request(text) else {
            pending = nil
            generation += 1
            isTranslating = false
            translation = nil
            translatedText = nil
            return
        }
        if request == translatedText, translation != nil {
            // Back to text that's already translated (an edit undone).
            pending = nil
            generation += 1
            isTranslating = false
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            await self?.translate(request)
        }
    }

    /// One request for `request`. A newer request, or closing, makes its answer stale.
    private func translate(_ request: String) async {
        guard let api, let source, let target else { return }
        generation += 1
        let mine = generation
        isTranslating = true
        let body = TranslateRequest(text: request, from: source.tag, to: target.tag, situation: situation())
        let started = ContinuousClock.now
        do {
            let response = try await api.translate(body)
            guard mine == generation else { return }
            translation = response.translation
            translatedText = request
            failure = nil
            RyokoLog.translate.info("Translated \(request.count) characters in \(ContinuousClock.now - started, privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation else { return }
            failure = (error as? RyokoAPIError)?.errorDescription ?? "Couldn't translate. Try again."
            RyokoLog.translate.error("Translate failed: \(String(describing: error), privacy: .public)")
        }
        if mine == generation { isTranslating = false }
    }

    // MARK: Done

    /// What Done commits: your words and their translation. It translates
    /// first if the shown translation is out of date. nil means nothing to
    /// commit: empty text, an unchanged edit, or a failed translation (shown).
    func finish() async -> (text: String, translation: String)? {
        guard let request = TypedText.request(text) else { return nil }
        if case .editing(let turn) = purpose, request == turn.original, translation == turn.translation {
            return nil
        }
        if translatedText == request, let translation { return (request, translation) }
        pending?.cancel()
        pending = nil
        isFinishing = true
        defer { isFinishing = false }
        await translate(request)
        guard translatedText == request, let translation else { return nil }
        return (request, translation)
    }

    #if DEBUG
    /// DEBUG launch options: put text in the field as if typed.
    func debugType(_ raw: String) {
        update(raw)
    }
    #endif
}
