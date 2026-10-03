import Foundation
import os

/// Loggers for the app. Read them with Console.app or
/// `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.danielou.ryoko"'`.
/// Never log secrets: no tokens, no full request headers.
nonisolated enum RyokoLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.danielou.ryoko"

    static let api = Logger(subsystem: subsystem, category: "api")
    static let fixtures = Logger(subsystem: subsystem, category: "fixtures")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let places = Logger(subsystem: subsystem, category: "places")
}
