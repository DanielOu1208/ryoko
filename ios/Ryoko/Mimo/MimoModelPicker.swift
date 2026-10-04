import SwiftUI

/// The composer's model button (design §4.9): the level Mimo thinks at, like
/// Codex's effort button. Tap it for a popover with the level in large type,
/// the model under it (tap for the list), and a slider across the levels the
/// model takes, coloured warm to cool as the level rises. Hidden until the
/// server's list is in.
struct MimoModelButton: View {
    let store: MimoModelStore
    /// The height of the composer's Send button, to line up with it.
    let height: CGFloat

    @State private var isPresented = false

    var body: some View {
        if let current = store.current {
            Button { isPresented = true } label: {
                HStack(spacing: 3) {
                    Text(current.effort.title)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .imageScale(.small)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Theme.grid * 1.25)
                .frame(height: height)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model")
            .accessibilityValue("\(current.model.name), \(current.effort.title)")
            .accessibilityHint("Changes the model and how long Mimo thinks")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                MimoModelPanel(store: store)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// The popover: the level, the model and the slider, with a reset to the
/// server's default; the model's name turns the popover to the list of models.
private struct MimoModelPanel: View {
    let store: MimoModelStore

    @State private var showsModels = false

    var body: some View {
        if let current = store.current, let catalog = store.catalog {
            Group {
                if showsModels {
                    MimoModelList(catalog: catalog, selectedID: current.model.id) { model in
                        store.pick(model: model)
                        showsModels = false
                    } onBack: {
                        showsModels = false
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    levels(current: current)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(width: 300)
            .animation(.smooth(duration: 0.25), value: showsModels)
        }
    }

    private func levels(current: (model: MimoModel, effort: MimoEffort)) -> some View {
        VStack(spacing: Theme.grid * 2) {
            HStack(alignment: .top) {
                // Balances the reset button, so the titles stay centred.
                Color.clear.frame(width: 32, height: 32)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(current.effort.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(current.effort.tint)
                        .contentTransition(.opacity)
                    Button { showsModels = true } label: {
                        HStack(spacing: 2) {
                            Text(current.model.name)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Model")
                    .accessibilityValue(current.model.name)
                    .accessibilityHint("Shows the models")
                }
                Spacer(minLength: 0)
                Button("Reset to default", systemImage: "arrow.counterclockwise", action: store.reset)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
                    .foregroundStyle(store.isDefault ? .tertiary : .secondary)
                    .disabled(store.isDefault)
            }
            MimoEffortSlider(
                levels: current.model.efforts,
                selection: Binding(get: { current.effort }, set: { store.pick(effort: $0) })
            )
        }
        .padding(Theme.grid * 2)
        .animation(.smooth(duration: 0.25), value: current.effort)
    }
}

/// Every model, under its provider, with a checkmark on the one in use.
private struct MimoModelList: View {
    let catalog: MimoModelsResponse
    let selectedID: String
    var onPick: (MimoModel) -> Void
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: Theme.grid / 2) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                    Text("Model")
                        .font(.headline)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .padding(.horizontal, Theme.grid * 2)
            .padding(.top, Theme.grid * 2)
            .padding(.bottom, Theme.grid)
            ForEach(providers, id: \.self) { provider in
                Text(catalog.models.first { $0.provider == provider }?.providerName ?? provider)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.grid * 2)
                    .padding(.top, Theme.grid * 1.5)
                    .padding(.bottom, Theme.grid / 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(catalog.models.filter { $0.provider == provider }) { model in
                    Button { onPick(model) } label: {
                        HStack(spacing: Theme.grid) {
                            Text(model.name)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if model.id == selectedID {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, Theme.grid * 2)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(MimoModelRowStyle())
                    .accessibilityAddTraits(model.id == selectedID ? .isSelected : [])
                }
            }
        }
        .padding(.bottom, Theme.grid)
    }

    /// The providers in the list's order.
    private var providers: [String] {
        catalog.models.reduce(into: [String]()) { list, model in
            if !list.contains(model.provider) { list.append(model.provider) }
        }
    }
}

/// A list row that highlights while pressed.
private struct MimoModelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(uiColor: .tertiarySystemFill) : .clear)
    }
}

/// A row of stops, one per level, with a knob on the chosen one: drag or tap
/// along it. The track fills up to the knob in the level's colour.
private struct MimoEffortSlider: View {
    let levels: [MimoEffort]
    @Binding var selection: MimoEffort

    private static let trackHeight: CGFloat = 32
    private static let knobSize: CGFloat = 38

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let index = levels.firstIndex(of: selection) ?? 0
            let knobX = x(of: index, in: width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(selection.tint)
                    .frame(width: knobX + Self.trackHeight / 2, height: Self.trackHeight)
                ForEach(levels.indices, id: \.self) { stop in
                    if stop != index {
                        Circle()
                            .fill(stop < index ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                            .frame(width: 6, height: 6)
                            .position(x: x(of: stop, in: width), y: Self.knobSize / 2)
                    }
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .position(x: knobX, y: Self.knobSize / 2)
            }
            .frame(height: Self.knobSize)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let stop = nearestStop(to: value.location.x, in: width)
                        if levels[stop] != selection { selection = levels[stop] }
                    }
            )
            .animation(.snappy(duration: 0.2), value: selection)
        }
        .frame(height: Self.knobSize)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityRepresentation {
            Slider(value: stopValue, in: 0...Double(max(levels.count - 1, 1)), step: 1) {
                Text("Thinking")
            }
            .accessibilityValue(selection.title)
        }
    }

    /// The selection as a stop number, for VoiceOver's slider.
    private var stopValue: Binding<Double> {
        Binding(
            get: { Double(levels.firstIndex(of: selection) ?? 0) },
            set: { value in
                let stop = min(max(Int(value.rounded()), 0), levels.count - 1)
                if levels.indices.contains(stop) { selection = levels[stop] }
            }
        )
    }

    /// Where a stop's centre sits: the ends are inset by half the track's height.
    private func x(of stop: Int, in width: CGFloat) -> CGFloat {
        let inset = Self.trackHeight / 2
        guard levels.count > 1 else { return inset }
        return inset + CGFloat(stop) * (width - 2 * inset) / CGFloat(levels.count - 1)
    }

    private func nearestStop(to x: CGFloat, in width: CGFloat) -> Int {
        levels.indices.min { abs(self.x(of: $0, in: width) - x) < abs(self.x(of: $1, in: width) - x) } ?? 0
    }
}

extension MimoEffort {
    /// Warm when Mimo answers at once, cooler as it thinks longer.
    var tint: Color {
        switch self {
        case .off: .orange
        case .minimal: .green
        case .low: .teal
        case .medium: .blue
        case .high: .indigo
        default: .secondary
        }
    }
}
