import SwiftUI

// MARK: - 3. What you don't eat

struct DietSections: View {
    @Binding var draft: SurveyDraft

    var body: some View {
        Section {
            ChipGroup(
                values: Diet.allCases,
                title: ProfileWording.diet,
                isSelected: draft.diet.contains,
                toggle: { diet in
                    if draft.diet.contains(diet) { draft.diet.remove(diet) } else { draft.diet.insert(diet) }
                }
            )
        }
        Section("Anything else") {
            TextField("For example, no raw onion", text: $draft.dietNotes, axis: .vertical)
                .lineLimit(1...4)
                .onChange(of: draft.dietNotes) { _, new in
                    if new.count > SurveyOptions.maxDietNotesLength {
                        draft.dietNotes = String(new.prefix(SurveyOptions.maxDietNotesLength))
                    }
                }
        }
    }
}

// MARK: - 4. Allergies

struct AllergiesSections: View {
    @Binding var draft: SurveyDraft

    /// A chip allergen, or one typed in.
    private enum Chip: Hashable {
        case listed(AllergenId)
        case typed(String)
    }

    var body: some View {
        Section {
            ChipGroup(values: chips, title: title, isSelected: isSelected, toggle: toggle)
            AddItemField(prompt: "Something else", limit: SurveyOptions.maxAllergyLabelLength) { label in
                // Typing a listed allergen selects its chip, which has reviewed wording.
                let listed = AllergenId.chips.first { ProfileWording.allergen($0).lowercased() == label.lowercased() }
                let chip = listed.map(Chip.listed) ?? .typed(label)
                guard !isSelected(chip), draft.allergies.count < SurveyOptions.maxAllergies else { return }
                draft.allergies.append(Allergy(id: listed ?? .custom, label: listed == nil ? label : nil, severity: .serious))
            }
        }
        if !draft.allergies.isEmpty {
            Section {
                ForEach($draft.allergies, id: \.surveyKey) { $allergy in
                    Picker(selection: $allergy.severity) {
                        ForEach(Severity.allCases, id: \.self) { severity in
                            Text(ProfileWording.severityTitle(severity)).tag(severity)
                        }
                    } label: {
                        Text(ProfileWording.allergen(allergy))
                    }
                    .pickerStyle(.menu)
                }
                .onDelete { draft.allergies.remove(atOffsets: $0) }
            } header: {
                Text("How serious")
            } footer: {
                Text("Mild: avoid it if possible. Serious: none at all, including oils and sauces. Life-threatening: even a trace is dangerous.")
            }
        }
    }

    /// The listed allergens, then any typed in.
    private var chips: [Chip] {
        AllergenId.chips.map(Chip.listed) + draft.allergies.compactMap { allergy in
            allergy.id == .custom ? allergy.label.map(Chip.typed) : nil
        }
    }

    private func title(_ chip: Chip) -> String {
        switch chip {
        case let .listed(id): ProfileWording.allergen(id)
        case let .typed(label): label
        }
    }

    private func isSelected(_ chip: Chip) -> Bool {
        draft.allergies.contains { $0.surveyKey == key(chip) }
    }

    /// Selecting adds the allergen as serious; the picker below changes that.
    private func toggle(_ chip: Chip) {
        if let index = draft.allergies.firstIndex(where: { $0.surveyKey == key(chip) }) {
            draft.allergies.remove(at: index)
        } else if case let .listed(id) = chip, draft.allergies.count < SurveyOptions.maxAllergies {
            draft.allergies.append(Allergy(id: id, label: nil, severity: .serious))
        }
    }

    private func key(_ chip: Chip) -> String {
        switch chip {
        case let .listed(id): id.rawValue
        case let .typed(label): "custom:\(label.lowercased())"
        }
    }
}

extension Allergy {
    /// One per allergen: the id, or the label for a typed-in one.
    nonisolated var surveyKey: String {
        id == .custom ? "custom:\((label ?? "").lowercased())" : id.rawValue
    }
}

// MARK: - 5. Your usual

struct UsualSections: View {
    @Binding var draft: SurveyDraft

    var body: some View {
        favourites("Food", options: SurveyOptions.foods, items: $draft.foods, prompt: "Another food")
        favourites("Drinks", options: SurveyOptions.drinks, items: $draft.drinks, prompt: "Another drink")
        Section {
            TasteSlider(title: "Sweetness", noun: "sweet", value: $draft.sweetness)
            TasteSlider(title: "Spice", noun: "spicy", value: $draft.spice)
        } header: {
            Text("Taste")
        }
    }

    private func favourites(_ title: String, options: [String], items: Binding<[String]>, prompt: String) -> some View {
        Section(title) {
            ChipGroup(
                values: options + items.wrappedValue.filter { !options.contains($0) },
                title: ProfileWording.favourite,
                isSelected: items.wrappedValue.contains,
                toggle: { item in
                    if let index = items.wrappedValue.firstIndex(of: item) {
                        items.wrappedValue.remove(at: index)
                    } else if items.wrappedValue.count < SurveyOptions.maxFavourites {
                        items.wrappedValue.append(item)
                    }
                }
            )
            AddItemField(prompt: prompt, limit: SurveyOptions.maxFavouriteLength) { typed in
                // Typing a listed one selects its chip.
                let item = options.first { $0.lowercased() == typed.lowercased() } ?? typed
                guard items.wrappedValue.count < SurveyOptions.maxFavourites,
                      !items.wrappedValue.contains(where: { $0.lowercased() == item.lowercased() })
                else { return }
                items.wrappedValue.append(item)
            }
        }
    }
}

/// A 5-step system slider from 0 to 4; the middle means "as usual".
private struct TasteSlider: View {
    let title: String
    let noun: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid) {
            LabeledContent(title) {
                Text(ProfileWording.taste(value, noun: noun))
                    .contentTransition(.interpolate)
            }
            Slider(
                value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                in: 0...4,
                step: 1
            ) {
                Text(title)
            } minimumValueLabel: {
                Text("Less").font(.footnote).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("More").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityValue(ProfileWording.taste(value, noun: noun))
            .sensoryFeedback(.selection, trigger: value)
        }
        .padding(.vertical, Theme.grid / 2)
        .animation(.snappy, value: value)
    }
}
