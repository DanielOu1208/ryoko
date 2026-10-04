import SwiftUI

/// The bottom of Translate: the status line, the big mic button with the
/// smaller keyboard button beside it (Type mode, T2.4), and the pair menu.
struct TranslateControls: View {
    let model: TranslateModel
    let pair: TranslatePair?
    /// A caveat about the pair (Cantonese in Hong Kong), if any.
    let note: String?
    let options: [PairLanguage]
    let homeTag: String
    let situationLanguage: String?
    @Binding var manualHome: String?
    @Binding var manualOther: String?
    let toggle: () -> Void
    /// Opens Type mode.
    let type: () -> Void

    @ScaledMetric(relativeTo: .title3) private var sideButton: CGFloat = 52

    var body: some View {
        VStack(spacing: Theme.grid * 1.5) {
            status
            HStack(spacing: Theme.grid * 3) {
                // Keeps the mic button centred.
                Color.clear
                    .frame(width: sideSize, height: sideSize)
                    .accessibilityHidden(true)
                MicButton(
                    isListening: model.phase == .listening,
                    isBusy: model.phase == .starting || model.phase == .finishing,
                    level: model.level,
                    action: toggle
                )
                .disabled(pair == nil && !model.isActive)
                KeyboardButton(size: sideSize, action: type)
                    .disabled(pair == nil)
            }
            pairMenu
            if let note, !model.isActive {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        // The panes get the room at accessibility sizes; the controls stop growing here.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, Theme.margin)
        .padding(.top, Theme.grid * 1.5)
        .padding(.bottom, Theme.grid * 2)
        .frame(maxWidth: .infinity)
    }

    private var sideSize: CGFloat { min(sideButton, 72) }

    private var status: some View {
        Group {
            if let problem = model.problem {
                if model.display == nil {
                    // The problem is already shown above, in full.
                    Text(problem.isRetryable ? "Tap the mic to try again" : "Not listening")
                } else {
                    Label(problem.title, systemImage: problem.systemImage)
                }
            } else if pair == nil, !model.isActive {
                Text("Pick their language to start")
            } else {
                Text(model.statusText)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(model.problem != nil && model.display != nil ? .primary : .secondary)
        .multilineTextAlignment(.center)
        .contentTransition(.opacity)
        .animation(.default, value: model.statusText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Pair

    private var pairMenu: some View {
        Menu {
            Picker("Their language", selection: otherSelection) {
                if let here = situationLanguage.flatMap(PairLanguage.init(tag:)) {
                    Text("Here: \(here.name)").tag("")
                }
                ForEach(options.filter { $0.sonioxCode != homeLanguage.sonioxCode }) { language in
                    Text(language.name).tag(language.tag)
                }
            }
            .pickerStyle(.inline)
            Picker("Your language", selection: homeSelection) {
                Text("From your profile: \(PairLanguage(tag: homeTag)?.name ?? homeTag)").tag("")
                ForEach(options) { language in
                    Text(language.name).tag(language.tag)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Label(pair?.label ?? "Choose languages", systemImage: "character.bubble")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(model.isActive)
        .accessibilityHint(model.isActive ? "Stop listening to change languages." : "Changes the languages to translate between.")
    }

    private var homeLanguage: PairLanguage {
        PairLanguage(tag: manualHome ?? homeTag) ?? PairLanguage(.en)
    }

    /// "" means automatic (the situation's language).
    private var otherSelection: Binding<String> {
        Binding(get: { manualOther ?? "" }, set: { manualOther = $0.isEmpty ? nil : $0 })
    }

    /// "" means the profile's home language.
    private var homeSelection: Binding<String> {
        Binding(get: { manualHome ?? "" }, set: { manualHome = $0.isEmpty ? nil : $0 })
    }
}

/// The smaller round keyboard button beside the mic: opens Type mode.
/// Liquid Glass, like the mic (a floating control, design §9.4).
struct KeyboardButton: View {
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "keyboard")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Type")
        .accessibilityHint("Type what you want to say instead.")
    }
}

/// The big round mic button: Liquid Glass (a floating control, design §9.4),
/// red while listening (red is for recording), with a ring that follows the level.
struct MicButton: View {
    let isListening: Bool
    let isBusy: Bool
    let level: Float
    let action: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat { min(diameter, 120) }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.title)
                        .foregroundStyle(isListening ? Color.white : Color.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(isListening ? .regular.tint(.red).interactive() : .regular.interactive(), in: Circle())
        .background {
            if isListening, !reduceMotion {
                Circle()
                    .stroke(Color.red.opacity(0.35), lineWidth: 4)
                    .scaleEffect(1.06 + CGFloat(level) * 0.22)
                    .animation(.easeOut(duration: 0.15), value: level)
            }
        }
        .accessibilityLabel(isListening ? "Stop listening" : (isBusy ? "Stop" : "Start listening"))
    }
}
