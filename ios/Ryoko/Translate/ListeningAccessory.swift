import SwiftUI

/// The tab bar's bottom accessory while Translate listens (design §3, T2.5):
/// "Listening · English ⇄ Japanese" with a stop button, on every tab but
/// Translate (which has the big mic button). Tapping the label opens
/// Translate. When the tab bar minimizes on scroll, the accessory sits inline
/// beside it and shortens to "Listening".
///
/// `RootTabView` shows it with `tabViewBottomAccessory(isEnabled:)`.
struct ListeningAccessory: View {
    let model: TranslateModel
    /// Opens the Translate tab.
    let open: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var stops = 0

    /// Whether `RootTabView` should show the accessory on `tab`.
    static func isShown(for model: TranslateModel, on tab: AppTab) -> Bool {
        (model.isActive || model.isPaused) && tab != .translate
    }

    private var isListening: Bool { model.phase == .listening }

    var body: some View {
        HStack(spacing: Theme.grid * 1.5) {
            Button(action: open) {
                HStack(spacing: Theme.grid) {
                    Image(systemName: model.isPaused ? "pause.fill" : "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isListening && !reduceMotion)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint("Opens Translate.")

            Button {
                stops += 1
                model.stopAndForgetPause(.user)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body)
                    .foregroundStyle(.red)
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .finishing)
            .accessibilityLabel("Stop listening")
        }
        .padding(.horizontal, Theme.grid * 2)
        // The accessory's height is fixed by the system; past this it would clip.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sensoryFeedback(.stop, trigger: stops)
    }

    /// "Listening · English ⇄ Japanese", or just "Listening" inline and at
    /// accessibility text sizes (the full line would be cut mid-word).
    private var title: String {
        let state: String = switch model.phase {
        case .starting: "Connecting"
        case .finishing: model.isPaused ? "Paused" : "Finishing"
        case .listening: "Listening"
        case .idle: model.isPaused ? "Paused" : "Listening"
        }
        guard placement != .inline, !dynamicTypeSize.isAccessibilitySize, let pair = model.sessionPair else { return state }
        return "\(state) · \(pair.label)"
    }

    private var accessibilityTitle: String {
        guard let pair = model.sessionPair else { return title }
        return "\(title.components(separatedBy: " · ").first ?? title), \(pair.home.name) and \(pair.other.name)"
    }
}
