import Foundation
import os

/// Translate (design §4.8, W5): live two-way speech translation through Soniox.
///
/// - `TranslateView`: the tab. Panes for the latest turn, upright or face to
///   face, the mic button, the pair menu and History.
/// - `TranslateModel`: one listening session at a time, the turns, the
///   2-minute silence stop and the idle timer.
/// - `TurnBuilder` (`TurnRule.swift`): the pure turn rule. `TiltRule`: the pure
///   layout rule. `TurnRuleCheck.swift` checks both on the Mac.
/// - `SonioxSession`, `SonioxRun`, `MicrophoneCapture`: the WebSocket client,
///   the session driver and 16 kHz capture.
enum TranslateFeature {}

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
/// - `-RyokoTranslateAutoStart 1`: start listening when Translate appears.
/// - `-RyokoTranslateOther <tag>` / `-RyokoTranslateHome <tag>`: pick the pair by hand.
/// - `-RyokoTranslateLayout upright|faceToFace`: force a layout.
/// - `-RyokoTranslateHistory <seconds>`: open History that long after appearing.
/// - `-RyokoTranslateCannedPace <factor>`: speed of the canned script (1 = real time).
/// - `-RyokoTranslateProblem <code>`: the canned run fails with this Soniox
///   error code (401, 402…), or `mic` for a denied microphone.
/// - `-RyokoTranslateSilenceSeconds <n>`: the silence stop after n seconds, not 120.
/// - `-RyokoTranslateSelfCheck 1`: run the turn-rule cases and log the result.
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
