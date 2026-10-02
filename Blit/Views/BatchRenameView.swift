// File › Rename N Items… (PRD R2.12): Finder's batch rename (replace text,
// add text, format) with a live preview and saved presets for naming
// conventions. Native sheet.

import SwiftUI

struct BatchRenameView: View {
    let browser: BrowserModel
    let items: [FileItem]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastRenameSteps") private var lastStepsData = Data()
    /// The rule is a list of steps run in order (a preset like Movies uses two).
    @State private var steps = [RenameRule()]
    @State private var selectedStep = 0
    @State private var presets = RenamePresets.all()
    @State private var savingPreset = false
    @State private var presetName = ""
    /// Opens with the last rule used, unless given steps (a test's picture).
    private let restoresLast: Bool

    init(browser: BrowserModel, items: [FileItem], steps: [RenameRule]? = nil) {
        self.browser = browser
        self.items = items
        restoresLast = steps == nil
        if let steps, !steps.isEmpty { _steps = State(initialValue: steps) }
    }

    private var rows: [RenamePlanRow] {
        RenamePlan.rows(items, steps: steps) { parent in
            (parent == browser.current ? browser.items : browser.children[parent] ?? []).map(\.name)
        }
    }

    var body: some View {
        let rows = rows
        let changing = rows.filter(\.changes)
        let problems = rows.filter { $0.problem != nil }
        VStack(spacing: 0) {
            Form {
                Section {
                    stepBar
                    Picker("Rename", selection: rule.mode) {
                        Text("Replace Text").tag(RenameRule.Mode.replace)
                        Text("Add Text").tag(RenameRule.Mode.add)
                        Text("Format").tag(RenameRule.Mode.format)
                    }
                    .pickerStyle(.segmented)
                    fields
                    Toggle("Include the extension", isOn: rule.includeExtension)
                    if selectedStep > 0 {
                        Toggle("Only if the step above changed the name", isOn: rule.onlyIfPreviousChanged)
                            .help("So a preset for one kind of name (movies, episodes) leaves other names alone")
                    }
                } header: {
                    HStack {
                        Text("Rename \(items.count) Items")
                        Spacer()
                        presetMenu
                    }
                }
                if savingPreset {
                    Section {
                        HStack {
                            TextField("Preset name", text: $presetName, prompt: Text("Scene → Plex"))
                                .onSubmit(savePreset)
                            Button("Save", action: savePreset).disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") { savingPreset = false }
                        }
                    }
                }
                Section("Preview") {
                    if let missing = unmatchedFind {
                        Label("No name contains “\(RenameRule.visibleSpaces(missing))”", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(rows) { row in previewRow(row) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(CGFloat(rows.count) * 36 + 8, 240))
                }
            }
            .formStyle(.grouped)
            HStack {
                if !problems.isEmpty {
                    Text("\(problems.count) name\(problems.count == 1 ? "" : "s") can't be used")
                        .font(.callout)
                        .foregroundStyle(Color.failureText)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(changing.isEmpty ? "Rename" : "Rename \(changing.count)") {
                    lastStepsData = (try? JSONEncoder().encode(steps)) ?? Data()
                    browser.commitBatchRename(changing)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changing.isEmpty || !problems.isEmpty)
            }
            .padding()
        }
        .frame(width: 520)
        .onAppear {
            if restoresLast, let last = try? JSONDecoder().decode([RenameRule].self, from: lastStepsData), !last.isEmpty { steps = last }
        }
    }

    /// The selected step, for the fields.
    private var rule: Binding<RenameRule> {
        Binding(get: { steps[min(selectedStep, steps.count - 1)] },
                set: { steps[min(selectedStep, steps.count - 1)] = $0 })
    }

    /// Spaces at either end of a field, drawn so they can be seen (␣): the
    /// field itself shows none, and the sheet opens with the last rule.
    @ViewBuilder private func spaceNote(_ field: String, _ text: String) -> some View {
        if let edge = RenameRule.edgeSpaces(text) {
            Label("\(field) \(edge): “\(RenameRule.visibleSpaces(text))”", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    /// The selected step's Find text, when it's plain text that no name
    /// contains (so the preview can say why nothing changes).
    private var unmatchedFind: String? {
        let step = rule.wrappedValue
        guard step.mode == .replace, !step.find.isEmpty, !step.regularExpression else { return nil }
        let found = items.contains { item in
            let name = step.includeExtension ? item.name : RenameRule.split(item.name).base
            return name.range(of: step.find, options: step.matchCase ? [] : [.caseInsensitive]) != nil
        }
        return found ? nil : step.find
    }

    /// Step 1 · Step 2 · + / −
    private var stepBar: some View {
        HStack {
            Picker("Step", selection: $selectedStep) {
                ForEach(steps.indices, id: \.self) { Text("Step \($0 + 1)").tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            Button {
                steps.append(RenameRule())
                selectedStep = steps.count - 1
            } label: { Image(systemName: "plus") }
            .help("Add a step that runs after the others")
            Button {
                steps.remove(at: selectedStep)
                selectedStep = max(0, selectedStep - 1)
            } label: { Image(systemName: "minus") }
            .disabled(steps.count == 1)
            .help("Remove this step")
        }
    }

    @ViewBuilder private var fields: some View {
        switch rule.wrappedValue.mode {
        case .replace:
            TextField("Find", text: rule.find)
            spaceNote("Find", rule.wrappedValue.find)
            TextField("Replace with", text: rule.replacement)
            spaceNote("Replace with", rule.wrappedValue.replacement)
            HStack {
                Toggle("Match case", isOn: rule.matchCase)
                Toggle("Regular expression", isOn: rule.regularExpression)
                    .help("Replace with can use $1, $2… for captured groups")
            }
        case .add:
            TextField("Text", text: rule.addText)
            Picker("Where", selection: rule.addBefore) {
                Text("after name").tag(false)
                Text("before name").tag(true)
            }
        case .format:
            Picker("Name format", selection: rule.format) {
                Text("Name and Index").tag(RenameRule.Format.index)
                Text("Name and Counter").tag(RenameRule.Format.counter)
                Text("Name and Date Modified").tag(RenameRule.Format.date)
            }
            TextField("Custom format", text: rule.customName, prompt: Text("File"))
            Picker("Where", selection: rule.numberBefore) {
                Text("after name").tag(false)
                Text("before name").tag(true)
            }
            if rule.wrappedValue.format != .date {
                TextField("Start numbers at", value: rule.startAt, format: .number.grouping(.never))
            }
        }
    }

    private var presetMenu: some View {
        Menu("Presets") {
            ForEach(presets) { preset in
                Button(preset.name) {
                    steps = preset.steps.isEmpty ? [RenameRule()] : preset.steps
                    selectedStep = 0
                }
            }
            if !presets.isEmpty { Divider() }
            Button("Save as Preset…") {
                presetName = ""
                savingPreset = true
            }
            .disabled(!steps.contains(where: \.isActive))
            if !presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(presets) { preset in
                        Button(preset.name) {
                            presets.removeAll { $0.id == preset.id }
                            RenamePresets.save(presets)
                        }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.callout)
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        presets.removeAll { $0.name == name }
        presets.append(RenamePreset(name: name, steps: steps))
        RenamePresets.save(presets)
        savingPreset = false
    }

    private func previewRow(_ row: RenamePlanRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.item.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                Text(row.changes ? row.newName : "unchanged")
                    .foregroundStyle(row.problem != nil ? Color.failureText : row.changes ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let problem = row.problem {
                    Text("· \(problem)").foregroundStyle(Color.failureText).lineLimit(1)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}
