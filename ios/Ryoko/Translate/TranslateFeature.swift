import Foundation
import os

/// Translate (design §4.8, W5): live two-way speech translation through Soniox.
///
/// - `TranslateView`: the tab. Panes for the latest turn, upright or face to
///   face, the mic button, the keyboard button, the pair menu and History.
/// - `TranslateModel`: one listening session at a time, the turns, the
///   2-minute silence stop, the pause for typing and the idle timer. The app
///   owns it (`RyokoApp` puts it in the environment).
/// - `TranslateComposer` + `TranslateComposerView`: Type mode and the turn
///   editor, translated by `POST /v1/translate` (T2.4).
/// - `ListeningAccessory`: the tab bar's accessory while listening (T2.5).
/// - `SonioxKeyProvider`: a temporary key from the server per session, or the
///   build's key when the server can't hand one out (T2.6).
/// - `TurnBuilder` (`TurnRule.swift`): the pure turn rule. `TiltRule`: the pure
///   layout rule. `TurnRuleCheck.swift` checks both on the Mac.
/// - `SonioxSession`, `SonioxRun`, `MicrophoneCapture`: the WebSocket client,
///   the session driver and 16 kHz capture.
enum TranslateFeature {}

extension TranslateModel {
    /// The app's model: the microphone in release builds; in DEBUG, the source
    /// and silence limit from the launch arguments.
    static func forLaunch() -> TranslateModel {
        #if DEBUG
        let silence = TranslateDebug.silenceSeconds.map { Duration.seconds($0) } ?? .seconds(120)
        return TranslateModel(source: TranslateDebug.source, silenceLimit: silence, turnMode: TranslateDebug.turnMode)
        #else
        return TranslateModel()
        #endif
    }
}

#if DEBUG
/// DEBUG launch arguments for Translate (there's no tap automation):
///
///     xcrun simctl launch <udid> com.danielou.ryoko -RyokoInitialTab translate \
///       -RyokoTranslateSource canned -RyokoTranslateAutoStart 1 \
///       -RyokoTranslateOther zh-Hans -RyokoTranslateLayout faceToFace
///
/// - `-RyokoTranslateSource microphone|silence|canned`: where the words come
///   from. `silence` streams silence to the real Soniox (checks the key and
///   its errors without a microphone); `canned` plays a scripted conversation.
/// - `-RyokoTranslateAutoStart 1`: start listening at launch, whichever tab
///   opens (so the Listening accessory shows on the others).
/// - `-RyokoTranslateOther <tag>` / `-RyokoTranslateHome <tag>`: pick the pair by hand.
/// - `-RyokoTranslateLayout upright|faceToFace`: force a layout.
/// - `-RyokoTranslateTurns manual|automatic`: how turns change hands (manual by
///   default). With the canned source, manual turns hand over at each line.
/// - `-RyokoTranslateHistory <seconds>`: open History that long after appearing.
/// - `-RyokoTranslateCannedPace <factor>`: speed of the canned script (1 = real time).
/// - `-RyokoTranslateProblem <code>`: the canned run fails with this Soniox
///   error code (401, 402…), or `mic` for a denied microphone.
/// - `-RyokoTranslateSilenceSeconds <n>`: the silence stop after n seconds, not 120.
/// - `-RyokoTranslateSelfCheck 1`: run the turn-rule cases and log the result.
/// - `-RyokoTranslateType "<text>"`: when Translate appears, open Type mode
///   and type this (after `-RyokoTranslateTypeDelay <seconds>`, default 0.5).
///   `-RyokoTranslateTypeDone <seconds>` then presses Done that much later.
///   `-RyokoTranslateTypeWordGap <seconds>` types it a word at a time with that
///   gap instead (0.7 lets each request start, then cancels it with the next word).
/// - `-RyokoTranslateEdit <seconds>`: that long after Translate appears, open
///   the editor on your latest turn (listening pauses); `-RyokoTranslateEditText
///   "<text>"` then replaces your words with this, and `-RyokoTranslateEditDone
///   <seconds>` presses Done that much later (listening picks up again).
enum TranslateDebug {
    private static var defaults: UserDefaults { .standard }

    static var source: TranscriptionSourceKind {
        defaults.string(forKey: "RyokoTranslateSource").flatMap(TranscriptionSourceKind.init(rawValue:)) ?? .microphone
    }

    static var autoStart: Bool { defaults.bool(forKey: "RyokoTranslateAutoStart") }
    static var manualOther: String? { defaults.string(forKey: "RyokoTranslateOther") }
    static var manualHome: String? { defaults.string(forKey: "RyokoTranslateHome") }

    static var forcedLayout: TranslateLayout? {
        defaults.string(forKey: "RyokoTranslateLayout").flatMap(TranslateLayout.init(rawValue:))
    }

    static var turnMode: TurnMode {
        defaults.string(forKey: "RyokoTranslateTurns").flatMap(TurnMode.init(rawValue:)) ?? .manual
    }

    static var historyDelay: Double? {
        defaults.object(forKey: "RyokoTranslateHistory") == nil ? nil : defaults.double(forKey: "RyokoTranslateHistory")
    }

    static var cannedPace: Double {
        let pace = defaults.double(forKey: "RyokoTranslateCannedPace")
        return pace > 0 ? pace : 1
    }

    static var injectedProblem: TranslateProblem? {
        guard let raw = defaults.string(forKey: "RyokoTranslateProblem") else { return nil }
        if raw == "mic" { return .microphoneDenied }
        return Int(raw).map { TranslateProblem.soniox(code: $0, type: nil, message: nil) }
    }

    static var silenceSeconds: Double? {
        let seconds = defaults.double(forKey: "RyokoTranslateSilenceSeconds")
        return seconds > 0 ? seconds : nil
    }

    static var typeText: String? { defaults.string(forKey: "RyokoTranslateType") }

    static var typeDelay: Double {
        defaults.object(forKey: "RyokoTranslateTypeDelay") == nil ? 0.5 : defaults.double(forKey: "RyokoTranslateTypeDelay")
    }

    static var typeWordGap: Double? {
        defaults.object(forKey: "RyokoTranslateTypeWordGap") == nil ? nil : defaults.double(forKey: "RyokoTranslateTypeWordGap")
    }

    static var typeDoneDelay: Double? {
        defaults.object(forKey: "RyokoTranslateTypeDone") == nil ? nil : defaults.double(forKey: "RyokoTranslateTypeDone")
    }

    static var editDelay: Double? {
        defaults.object(forKey: "RyokoTranslateEdit") == nil ? nil : defaults.double(forKey: "RyokoTranslateEdit")
    }

    static var editText: String? { defaults.string(forKey: "RyokoTranslateEditText") }

    static var editDoneDelay: Double? {
        defaults.object(forKey: "RyokoTranslateEditDone") == nil ? nil : defaults.double(forKey: "RyokoTranslateEditDone")
    }

    /// `-RyokoTranslateAutoStart 1`: starts listening at launch with the pair
    /// Translate would use (waiting up to 10 s for the situation if no
    /// language was picked with `-RyokoTranslateOther`).
    @MainActor
    static func autoStartIfAsked(
        model: TranslateModel,
        homeTag: @escaping () -> String,
        situationLanguage: @escaping () -> String?,
        api: any RyokoAPI
    ) async {
        guard autoStart, !model.isActive, model.history.isEmpty else { return }
        for _ in 0..<40 {
            if let pair = PairChoice.resolve(
                homeTag: homeTag(),
                situationLanguage: situationLanguage(),
                manualHome: manualHome,
                manualOther: manualOther
            ) {
                await model.start(pair: pair, api: api)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        RyokoLog.translate.notice("Auto start: no pair after 10 s")
    }

    /// Runs the turn-rule cases in the app and logs them (`-RyokoTranslateSelfCheck 1`).
    static func runSelfCheckIfAsked() {
        guard defaults.bool(forKey: "RyokoTranslateSelfCheck") else { return }
        let ok = TurnRuleCheck.report(TurnRuleCheck.runAll()) { line in
            RyokoLog.translate.notice("\(line, privacy: .public)")
        }
        RyokoLog.translate.notice("Turn-rule self-check \(ok ? "passed" : "FAILED", privacy: .public)")
    }
}
#endif
