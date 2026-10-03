import Foundation
import os

/// Reads the Mimo SSE stream one line at a time (design §7.7).
///
/// The server sends each event as exactly one `data: {json}` line followed by a
/// blank line, with no `event:` lines. It also sends a padding comment of more
/// than 512 bytes first and `: ping` every 15 s. So the reader:
/// - splits the byte stream at LF (0x0A) only, not with `AsyncBytes.lines`,
///   which also splits at U+0085, U+2028 and U+2029: those can sit raw inside a
///   JSON string (a web page title, say) and would cut an event in pieces,
/// - decodes every `data:` line as one `MimoEvent` (it doesn't wait for the
///   blank line),
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

    /// Feeds every event in a byte stream (URLSession's `AsyncBytes`) to `yield`,
    /// logging and skipping malformed ones. Lines end at LF only; `parse` drops a
    /// CR before it. Throws whatever the byte sequence throws (for example a
    /// dropped connection).
    static func read<Bytes: AsyncSequence>(
        bytes: Bytes,
        yield: (MimoEvent) -> Void
    ) async throws where Bytes.Element == UInt8 {
        var line: [UInt8] = []
        line.reserveCapacity(4096)
        for try await byte in bytes {
            if byte == 0x0A {
                handle(String(decoding: line, as: UTF8.self), yield: yield)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty {
            handle(String(decoding: line, as: UTF8.self), yield: yield)
        }
    }

    private static func handle(_ rawLine: String, yield: (MimoEvent) -> Void) {
        switch parse(rawLine) {
        case let .event(event):
            yield(event)
        case .ignored:
            break
        case let .malformed(reason):
            RyokoLog.api.error("Skipped a malformed Mimo event: \(reason, privacy: .public)")
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
