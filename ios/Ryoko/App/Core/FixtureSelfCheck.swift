#if DEBUG
import Foundation
import os

/// DEBUG-only check that every bundled fixture decodes into its Swift mirror and
/// encodes back to the same JSON. That proves the field names, the explicit
/// `null`s and the SSE parser match `contracts/`.
///
/// Not wired into any UI. To run it at launch, call
/// `FixtureSelfCheck.runAtLaunch()` from `RyokoApp.init()`; it works off the main
/// actor and logs one line per fixture plus a summary to the `fixtures` category:
///
///     xcrun simctl spawn booted log stream --level info \
///       --predicate 'subsystem == "com.danielou.ryoko" && category == "fixtures"'
///
/// `ios/scripts/check-contracts.sh` runs the same check on the Mac against
/// `contracts/examples/` directly.
nonisolated enum FixtureSelfCheck {
    struct Outcome: Sendable {
        var file: FixtureFile
        /// nil when the fixture passed.
        var failure: String?
        var passed: Bool { failure == nil }
    }

    /// Starts the check in the background and logs the result.
    static func runAtLaunch(source: FixtureSource = .mainBundle) {
        Task.detached(priority: .utility) {
            let outcomes = run(source: source)
            for outcome in outcomes {
                if let failure = outcome.failure {
                    RyokoLog.fixtures.error("FAIL \(outcome.file.fileName, privacy: .public): \(failure, privacy: .public)")
                } else {
                    RyokoLog.fixtures.info("pass \(outcome.file.fileName, privacy: .public)")
                }
            }
            let passed = outcomes.filter(\.passed).count
            if passed == outcomes.count {
                RyokoLog.fixtures.notice("Fixture self-check passed: \(passed) of \(outcomes.count)")
            } else {
                RyokoLog.fixtures.fault("Fixture self-check FAILED: \(passed) of \(outcomes.count) passed")
            }
        }
    }

    /// Checks every fixture and returns one outcome per file.
    static func run(source: FixtureSource = .mainBundle) -> [Outcome] {
        FixtureFile.allCases.map { file in
            do {
                try check(file, source: source)
                return Outcome(file: file, failure: nil)
            } catch {
                return Outcome(file: file, failure: String(describing: error))
            }
        }
    }

    private static func check(_ file: FixtureFile, source: FixtureSource) throws {
        if file == .mimoStream {
            try checkStream(source.text(file))
            return
        }
        let data = try source.data(file)
        switch file {
        case .profileSeed: try roundTrip(Profile.self, data)
        case .situationShanghai, .situationTokyo: try roundTrip(Situation.self, data)
        case .placeCardRequest, .placeCardTokyoRequest: try roundTrip(PlaceCardRequest.self, data)
        case .placeCardResponse, .placeCardTokyoResponse: try roundTrip(PlaceCardResponse.self, data)
        case .discoverRequest: try roundTrip(DiscoverRequest.self, data)
        case .discoverResponse: try roundTrip(DiscoverResponse.self, data)
        case .allergyCardRequest: try roundTrip(AllergyCardRequest.self, data)
        case .allergyCardResponse: try roundTrip(AllergyCardResponse.self, data)
        case .mimoMessageRequest: try roundTrip(MimoMessageRequest.self, data)
        case .errorInvalidRequest, .errorSessionBusy: try roundTrip(ErrorEnvelope.self, data)
        case .mimoStream: break
        }
    }

    /// Every `data:` line must decode to a known event and encode back unchanged,
    /// and the run must start with `start` and end with `done`.
    private static func checkStream(_ text: String) throws {
        var events: [MimoEvent] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            switch SSELineReader.parse(line) {
            case .ignored:
                continue
            case let .malformed(reason):
                throw CheckError("line \(index + 1): \(reason)")
            case let .event(event):
                if case let .unknown(type) = event {
                    throw CheckError("line \(index + 1): unknown event type \(type)")
                }
                let payload = String(line.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces)
                try roundTrip(MimoEvent.self, Data(payload.utf8), context: "line \(index + 1)")
                events.append(event)
            }
        }
        guard case .start = events.first else { throw CheckError("the stream doesn't open with a start event") }
        guard case .done = events.last else { throw CheckError("the stream doesn't end with a done event") }
    }

    private static func roundTrip<T: Codable>(_ type: T.Type, _ data: Data, context: String = "") throws {
        let value = try JSONDecoder().decode(type, from: data)
        let encoded = try JSONEncoder().encode(value)
        let original = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let again = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        if let difference = firstDifference(original, again, path: "$") {
            throw CheckError("\(context.isEmpty ? "" : context + ": ")round trip changed \(difference)")
        }
    }

    /// The first JSON path where two parsed JSON values differ, or nil.
    private static func firstDifference(_ a: Any, _ b: Any, path: String) -> String? {
        switch (a, b) {
        case let (a as [String: Any], b as [String: Any]):
            for key in Set(a.keys).union(b.keys).sorted() {
                guard let left = a[key] else { return "\(path).\(key) (added)" }
                guard let right = b[key] else { return "\(path).\(key) (dropped)" }
                if let difference = firstDifference(left, right, path: "\(path).\(key)") { return difference }
            }
            return nil
        case let (a as [Any], b as [Any]):
            guard a.count == b.count else { return "\(path) (length \(a.count) → \(b.count))" }
            for (index, pair) in zip(a, b).enumerated() {
                if let difference = firstDifference(pair.0, pair.1, path: "\(path)[\(index)]") { return difference }
            }
            return nil
        default:
            return (a as? NSObject)?.isEqual(b) == true ? nil : "\(path) (\(a) → \(b))"
        }
    }

    private struct CheckError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
#endif
