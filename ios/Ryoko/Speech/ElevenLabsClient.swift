import Foundation
import os

/// The ElevenLabs key and voice, from the Info.plist keys `RyokoElevenLabsAPIKey`
/// and `RyokoElevenLabsVoiceID` (filled from the gitignored Secrets.xcconfig),
/// read the same way as `SonioxCredentials`. Never log the key.
///
/// One voice speaks every language: `eleven_flash_v2_5` is multilingual, and
/// `language_code` pins the language. Pick a voice from the account's own
/// voices; the old stock voices only work on accounts made before March 2026.
nonisolated struct ElevenLabsCredentials: Sendable {
    static let keyInfoKey = "RyokoElevenLabsAPIKey"
    static let voiceInfoKey = "RyokoElevenLabsVoiceID"

    let apiKey: String
    let voiceID: String

    /// nil when the build has no key or no voice (empty, a placeholder, or an
    /// unexpanded `$(…)`): speech then stays on the device.
    static func fromBundle(_ bundle: Bundle = .main) -> ElevenLabsCredentials? {
        guard let apiKey = value(keyInfoKey, in: bundle),
              let voiceID = value(voiceInfoKey, in: bundle),
              voiceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return ElevenLabsCredentials(apiKey: apiKey, voiceID: voiceID)
    }

    private static func value(_ key: String, in bundle: Bundle) -> String? {
        let raw = ((bundle.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("$("), raw != "replace-me" else { return nil }
        return raw
    }
}

/// Text to speech over REST (design §8.1). The device calls ElevenLabs
/// directly; there's no Swift SDK.
nonisolated struct ElevenLabsClient: Sendable {
    /// Low latency, Chinese and Japanese included, and half the credits of
    /// `eleven_multilingual_v2`.
    static let model = "eleven_flash_v2_5"
    /// Small files for the cache; plenty for a short phrase.
    static let outputFormat = "mp3_44100_64"

    let credentials: ElevenLabsCredentials
    var urlSession: URLSession = .shared

    var voiceID: String { credentials.voiceID }

    enum Failure: Error {
        case http(Int)
        case empty
    }

    /// MP3 audio of `text`. `languageCode` is ISO 639-1 (`zh`, `ja`, `en`).
    @concurrent
    func audio(for text: String, languageCode: String?) async throws -> Data {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(credentials.voiceID)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: Self.outputFormat)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(credentials.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Body(text: text, model_id: Self.model, language_code: languageCode))

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // The error body is ElevenLabs' JSON (`detail.status`, `detail.message`); it never echoes the key.
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            RyokoLog.speech.error("ElevenLabs answered \(status): \(detail, privacy: .public)")
            throw Failure.http(status)
        }
        guard !data.isEmpty else { throw Failure.empty }
        return data
    }

    private struct Body: Encodable {
        var text: String
        var model_id: String
        var language_code: String?
    }
}
