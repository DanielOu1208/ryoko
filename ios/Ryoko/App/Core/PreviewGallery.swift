import SwiftUI

/// Every shared piece with fixture data, for checking styles in one place.
/// Open the #Previews below in Xcode's canvas.
struct PreviewGallery: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Local text") {
                    LocalTextSamples()
                }
                Section("Phrase cards") {
                    ForEach(Fixtures.shanghaiCard?.phrases ?? []) { phrase in
                        PhraseCardView(phrase: phrase, onShow: {})
                    }
                    if let tokyo = Fixtures.tokyoCard?.phrases.first {
                        PhraseCardView(phrase: tokyo, showsRomanization: false, onShow: {})
                    }
                }
                .galleryRow()
                Section("Phrase blocks") {
                    ForEach(GallerySamples.mimoPhrases) { phrase in
                        PhraseCardView(phrase: phrase, style: .block, onShow: {})
                    }
                }
                .galleryRow()
                Section("Tips") {
                    ForEach(Fixtures.shanghaiCard?.tips ?? [], id: \.text) { tip in
                        TipRow(tip: tip)
                    }
                }
                Section("Show content") {
                    ForEach(GallerySamples.showContents) { content in
                        LabeledContent(content.id, value: content.language)
                    }
                }
                Section("Mimo stream (fixture)") {
                    MimoReplay()
                }
                Section("Categories") {
                    ForEach(CategorySlug.allCases, id: \.self) { category in
                        Label(category.displayName, systemImage: category.sfSymbol)
                    }
                }
                Section("Languages") {
                    ForEach(LangCode.allCases, id: \.self) { lang in
                        LabeledContent {
                            LocalText(lang.nativeName, lang: lang)
                        } label: {
                            Text(lang.displayName)
                            Text("\(lang.tag) · Soniox \(lang.sonioxCode) · \(lang.localeIdentifier) · \(lang.romanization.rawValue)")
                        }
                    }
                }
            }
            .navigationTitle("Gallery")
        }
        .tint(.primary)
    }
}

/// The same characters in each CJK language, to check that the glyphs change.
private struct LocalTextSamples: View {
    var body: some View {
        ForEach([LangCode.zhHans, .ja, .zhHant], id: \.self) { lang in
            LabeledContent {
                LocalText("直 骨 角 今 关", lang: lang)
                    .font(.title2)
            } label: {
                Text(lang.displayName)
            }
        }
        LocalText("一杯招牌拿铁，少糖。", lang: .zhHans)
            .font(.title.weight(.semibold))
        LocalText("こちらまでお願いします", lang: .ja)
            .font(.title.weight(.semibold))
    }
}

/// Replays `mimo.sse.txt` through `FixtureRyokoAPI`, the way the Mimo tab will.
private struct MimoReplay: View {
    @State private var text = ""
    @State private var phrases: [Phrase] = []
    @State private var places: [ShownPlace] = []
    @State private var activity: String?
    @State private var finished = false
    @State private var run = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.isEmpty ? " " : text)
                .contentTransition(.opacity)
            ForEach(phrases) { phrase in
                PhraseCardView(phrase: phrase, style: .block, onShow: {})
            }
            if let activity {
                Text(activity)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(places, id: \.name) { place in
                Label(place.localName.map { "\(place.name) · \($0)" } ?? place.name, systemImage: "mappin")
                    .font(.subheadline)
            }
            if finished {
                Button("Replay", systemImage: "arrow.counterclockwise") { run += 1 }
                    .buttonStyle(.bordered)
            }
        }
        .task(id: run) { await replay() }
    }

    private func replay() async {
        text = ""
        phrases = []
        places = []
        activity = nil
        finished = false
        guard let request = Fixtures.mimoRequest else { return }
        do {
            for try await event in FixtureRyokoAPI().mimoMessages(sessionId: "gallery", request: request) {
                switch event {
                case let .text(delta): text += delta
                case let .phrase(phrase): phrases.append(phrase)
                case let .toolStart(_, _, label): activity = label
                case let .toolEnd(end):
                    activity = nil
                    if case let .showPlaces(details) = end.details { places = details.places }
                case .done: finished = true
                case let .error(body): text += "\n\(body.message)"
                case .start, .unknown: break
                }
            }
        } catch {
            text += "\n\(error.localizedDescription)"
            finished = true
        }
    }
}

private enum GallerySamples {
    static var mimoPhrases: [Phrase] {
        Fixtures.mimoEvents.compactMap { event in
            if case let .phrase(phrase) = event { phrase } else { nil }
        }
    }

    static var showContents: [ShowContent] {
        var contents: [ShowContent] = []
        if let phrase = Fixtures.shanghaiCard?.phrases.first {
            contents.append(.phrase(phrase))
        }
        if let card = Fixtures.allergyCard {
            contents.append(.allergy(AllergyShowCard(card)))
        }
        if let home = Fixtures.profile?.homeBase {
            contents.append(.taxi(TaxiShowCard(
                language: LangCode.zhHans.tag,
                name: home.localName ?? home.name,
                address: home.addressLocal ?? home.address ?? "",
                phrase: Phrase(id: "taxi-zh-Hans", lang: "zh-Hans", local: "请带我去这里", romanization: "Qǐng dài wǒ qù zhèlǐ", gloss: "Please take me here"),
                coordinate: home.coordinate,
                snapshot: nil
            )))
        }
        return contents
    }
}

private extension View {
    /// Cards sit on the grouped background without the list's own row chrome.
    func galleryRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .listRowSeparator(.hidden)
    }
}

#Preview("Gallery") {
    PreviewGallery()
}

#Preview("Phrase card") {
    ScrollView {
        VStack(spacing: 16) {
            ForEach(Fixtures.shanghaiCard?.phrases ?? []) { phrase in
                PhraseCardView(phrase: phrase, onShow: {})
            }
        }
        .padding(20)
    }
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Phrase card, Japanese, no romanization") {
    ScrollView {
        VStack(spacing: 16) {
            ForEach(Fixtures.tokyoCard?.phrases ?? []) { phrase in
                PhraseCardView(phrase: phrase, showsRomanization: false, onShow: {})
            }
        }
        .padding(20)
    }
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Phrase block") {
    VStack(spacing: 12) {
        ForEach(GallerySamples.mimoPhrases) { phrase in
            PhraseCardView(phrase: phrase, style: .block, onShow: {})
        }
    }
    .padding(20)
}

#Preview("Tips") {
    List(Fixtures.tokyoCard?.tips ?? [], id: \.text) { tip in
        TipRow(tip: tip)
    }
}

#Preview("Local text") {
    List { LocalTextSamples() }
}

#Preview("Mimo stream") {
    ScrollView {
        MimoReplay().padding(20)
    }
}
