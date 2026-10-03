import Foundation
import os

/// Reads the Mimo SSE stream one line at a time (design §7.7).
///
/// The server sends each event as exactly one `data: {json}` line followed by a
/// blank line, with no `event:` lines. It also sends a padding comment of more
/// than 512 bytes first and `: ping` every 15 s. So the reader:
/// - decodes every `data:` line as one `MimoEvent` (it doesn't wait for the blank
///   line, because `AsyncBytes.lines` drops blank lines),
/// - ignores comments (`:`), blank lines and other fields (`event:`, `id:`, `retry:`),
/// - reports a `data:` line it can't decode as `.malformed`, so the caller can log
///   it and keep reading.
nonisolated enum SSELineReader {
    /// What one line of the stream means.
    enum Line: Sendable, Equatable {
        case event(MimoEvent)
        /// A comment, a blank line or a field other than `data`.
        case ignored
        /// A `data:` line that isn't a valid event.
        case malformed(String)
    }

    /// Classifies one line (without its line terminator).
    static func parse(_ rawLine: some StringProtocol) -> Line {
        var line = Substring(rawLine)
        if line.hasSuffix("\r") { line = line.dropLast() }
        guard !line.isEmpty, !line.hasPrefix(":") else { return .ignored }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line
            value = ""
        }
        guard field == "data" else { return .ignored }

        do {
            let event = try JSONDecoder().decode(MimoEvent.self, from: Data(value.utf8))
            return .event(event)
        } catch {
            return .malformed(String(describing: error))
        }
    }

    /// Feeds every event in `lines` to `yield`, logging and skipping malformed ones.
    /// Throws whatever the line sequence throws (for example a dropped connection).
    static func read<Lines: AsyncSequence>(
        _ lines: Lines,
        yield: (MimoEvent) -> Void
    ) async throws where Lines.Element == String {
        for try await rawLine in lines {
            switch parse(rawLine) {
            case let .event(event):
                yield(event)
            case .ignored:
                continue
            case let .malformed(reason):
                RyokoLog.api.error("Skipped a malformed Mimo event: \(reason, privacy: .public)")
            }
        }
    }

    /// Every event in a whole transcript, such as the bundled `mimo.sse.txt`.
    /// Throws if any `data:` line is malformed.
    static func events(inTranscript text: String) throws -> [MimoEvent] {
        var events: [MimoEvent] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            switch parse(rawLine) {
            case let .event(event):
                events.append(event)
            case .ignored:
                continue
            case let .malformed(reason):
                throw RyokoAPIError.invalidResponse("Line \(index + 1) isn't a valid Mimo event: \(reason)")
            }
        }
        return events
    }
}
