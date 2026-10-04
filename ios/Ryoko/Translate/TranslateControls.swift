import SwiftUI

/// The bottom of Translate: the status line with the keyboard button (Type
/// mode, T2.4) on its right, then your language, the big mic button and their
/// language in one row, as in Google Translate. Each language is its own menu
/// of every language Soniox hears, Ryoko's own first; while listening (manual
/// turns, #68) the two become who's speaking: the speaker's is filled, and
/// tapping the other hands the turn over.
struct TranslateControls: View {
    let model: TranslateModel
    let pair: TranslatePair?
    /// A caveat about the pair (Cantonese in Hong Kong), if any.
    let note: String?
    let homeTag: String
    let situationLanguage: String?
    @Binding var manualHome: String?
    @Binding var manualOther: String?
    let toggle: () -> Void
    /// Opens Type mode.
    let type: () -> Void

    @ScaledMetric(relativeTo: .title3) private var sideButton: CGFloat = 44

    var body: some View {
        VStack(spacing: Theme.grid * 1.5) {
            // The status stays centred; Type sits at the trailing edge.
            status
                .padding(.horizontal, sideSize + Theme.grid)
                .frame(maxWidth: .infinity, minHeight: sideSize)
                .overlay(alignment: .trailing) {
                    KeyboardButton(size: sideSize, action: type)
                        .disabled(pair == nil)
                }
            HStack(spacing: Theme.grid * 1.5) {
                if let pair, showsSpeakers {
                    SpeakerPill(name: pair.home.name, isSpeaking: model.speaker == .me) { model.handOver(to: .me) }
                } else {
                    homeMenu
                }
                MicButton(
                    isListening: model.phase == .listening,
                    isBusy: model.phase == .starting || model.phase == .finishing,
                    level: model.level,
                    action: toggle
                )
                .disabled(pair == nil && !model.isActive)
                if let pair, showsSpeakers {
                    SpeakerPill(name: pair.other.name, isSpeaking: model.speaker == .them) { model.handOver(to: .them) }
                } else {
                    otherMenu
                }
            }
            .sensoryFeedback(.selection, trigger: model.speaker)
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

    private var sideSize: CGFloat { min(sideButton, 60) }

    /// While listening with manual turns, the pills say who's speaking.
    private var showsSpeakers: Bool { model.isActive && model.turnMode == .manual }

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

    // MARK: Languages

    /// Your language (left): the profile's, or one picked here.
    private var homeMenu: some View {
        Menu {
            Picker("Your language", selection: homeSelection) {
                Text("From your profile: \(PairLanguage(tag: homeTag)?.name ?? homeTag)").tag("")
                languageRows(PairChoice.featured)
            }
            .pickerStyle(.inline)
            moreLanguages(selection: homeSelection)
        } label: {
            LanguagePillLabel(name: homeLanguage.name)
        }
        .languagePill(isDisabled: model.isActive)
        .accessibilityLabel("Your language, \(homeLanguage.name)")
    }

    /// Their language (right): the place's, or one picked here.
    private var otherMenu: some View {
        Menu {
            Picker("Their language", selection: otherSelection) {
                if let here = situationLanguage.flatMap(PairLanguage.init(tag:)) {
                    Text("Here: \(here.name)").tag("")
                }
                languageRows(PairChoice.featured.filter { $0.sonioxCode != homeLanguage.sonioxCode })
            }
            .pickerStyle(.inline)
            moreLanguages(selection: otherSelection, excluding: homeLanguage.sonioxCode)
        } label: {
            LanguagePillLabel(name: pair?.other.name ?? "Choose")
        }
        .languagePill(isDisabled: model.isActive)
        .accessibilityLabel("Their language, \(pair?.other.name ?? "not chosen")")
    }

    private func languageRows(_ languages: [PairLanguage]) -> some View {
        ForEach(languages) { language in
            Text(language.name).tag(language.tag)
        }
    }

    /// The rest of Soniox's roster, A–Z below a divider. It's a second picker
    /// on the same selection: a menu draws no divider inside one picker.
    private func moreLanguages(selection: Binding<String>, excluding sonioxCode: String? = nil) -> some View {
        Picker("More languages", selection: selection) {
            languageRows(PairChoice.more.filter { $0.sonioxCode != sonioxCode })
        }
        .pickerStyle(.inline)
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

/// While listening (manual turns), one person's language: filled while it's
/// their turn, and a tap hands the turn to them.
private struct SpeakerPill: View {
    let name: String
    let isSpeaking: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isSpeaking {
                // Filled with the primary colour (black, or white in dark mode),
                // the label in the background's. The glass style's own label
                // colour stays white on a white fill.
                Button(action: action) {
                    label
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .padding(.horizontal, Theme.grid * 2)
                        .padding(.vertical, 10)
                        .background(Color.primary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isSpeaking ? "\(name), speaking now" : name)
        .accessibilityHint(isSpeaking ? "" : "Switches the turn to \(name).")
        .accessibilityAddTraits(isSpeaking ? .isSelected : [])
    }

    private var label: some View {
        HStack(spacing: Theme.grid * 0.75) {
            if isSpeaking {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    .accessibilityHidden(true)
            }
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 32)
    }
}

/// A language's name in a pill, with the menu's up-and-down chevron.
private struct LanguagePillLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: Theme.grid * 0.75) {
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 32)
    }
}

private extension View {
    /// One of the two language buttons beside the mic: a glass pill that
    /// takes half the row's spare width. Off while listening: the pair is fixed
    /// for a session.
    func languagePill(isDisabled: Bool) -> some View {
        self
            // Rows top to bottom as written, so the A–Z list reads downward.
            // Automatic order can put the first row nearest the pill instead.
            .menuOrder(.fixed)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(isDisabled)
            .accessibilityHint(isDisabled ? "Stop listening to change languages." : "Changes the language.")
    }
}
