import RulebookKit
import SwiftUI

/// Binding to "is this rule set included", keeping at least one rule set checked.
private func includeBinding(_ jurisdiction: Jurisdiction, in context: Binding<AnswerContext>) -> Binding<Bool> {
    Binding {
        context.wrappedValue.included.contains(jurisdiction)
    } set: { isOn in
        if isOn {
            context.wrappedValue.included.insert(jurisdiction)
        } else if context.wrappedValue.included.count > 1 {
            context.wrappedValue.included.remove(jurisdiction)
        }
    }
}

/// Toolbar menu: race type, role, and checkboxes for which rule sets to search.
struct RaceContextMenu: View {
    @Binding var context: AnswerContext

    var body: some View {
        Menu {
            Picker("Race", selection: $context.race) {
                ForEach(RaceContext.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Your role", selection: $context.role) {
                ForEach(OfficialRole.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Section("Include rule sets") {
                ForEach(Jurisdiction.allCases, id: \.self) { jurisdiction in
                    Toggle(jurisdiction.includeLabel, isOn: includeBinding(jurisdiction, in: $context))
                }
            }
        } label: {
            Label("Race & role", systemImage: "slider.horizontal.3")
        }
        .menuActionDismissBehavior(.disabled)  // keep the menu open while ticking several boxes
    }
}

/// Settings form sections for the defaults new conversations start with.
struct ContextDefaultsSections: View {
    @Binding var context: AnswerContext

    var body: some View {
        Section {
            Picker("Race", selection: $context.race) {
                ForEach(RaceContext.allCases) { Text($0.label).tag($0) }
            }
            Picker("Your role", selection: $context.role) {
                ForEach(OfficialRole.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("New questions start with")
        } footer: {
            Text("For an Oregon high-school race, OISRA rules take precedence over U.S. Ski & Snowboard and FIS rules. Your role steers answers toward that official's duties. Both can be changed in each conversation.")
        }
        Section {
            ForEach(Jurisdiction.allCases, id: \.self) { jurisdiction in
                Toggle(jurisdiction.includeLabel, isOn: includeBinding(jurisdiction, in: $context))
            }
        } header: {
            Text("Include rule sets")
        } footer: {
            Text("Unchecked rule sets are left out of search results entirely. For example, uncheck FIS for club races that never use FIS rules.")
        }
    }
}

/// A one-line summary under the engine banner: "OISRA · Referee · no FIS".
struct ContextSummaryBar: View {
    let context: AnswerContext

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: context.race == .oisra ? "graduationcap" : "flag.checkered")
            Text(context.summary)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.tint)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}
