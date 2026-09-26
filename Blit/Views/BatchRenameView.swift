// File › Rename N Items… (PRD R2.12): Finder's batch rename (replace text,
// add text, format) with a live preview and saved presets for naming
// conventions. Native sheet.

import SwiftUI

struct BatchRenameView: View {
    let browser: BrowserModel
    let items: [FileItem]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastRenameRule") private var lastRuleData = Data()
    @State private var rule = RenameRule()
    @State private var presets = RenamePresets.all()
    @State private var savingPreset = false
    @State private var presetName = ""

    private var rows: [RenamePlanRow] {
        RenamePlan.rows(items, rule: rule) { parent in
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
                    Picker("Rename", selection: $rule.mode) {
                        Text("Replace Text").tag(RenameRule.Mode.replace)
                        Text("Add Text").tag(RenameRule.Mode.add)
                        Text("Format").tag(RenameRule.Mode.format)
                    }
                    .pickerStyle(.segmented)
                    fields
                    Toggle("Include the extension", isOn: $rule.includeExtension)
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
                    lastRuleData = (try? JSONEncoder().encode(rule)) ?? Data()
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
            if let last = try? JSONDecoder().decode(RenameRule.self, from: lastRuleData) { rule = last }
        }
    }

    @ViewBuilder private var fields: some View {
        switch rule.mode {
        case .replace:
            TextField("Find", text: $rule.find)
            TextField("Replace with", text: $rule.replacement)
            HStack {
                Toggle("Match case", isOn: $rule.matchCase)
                Toggle("Regular expression", isOn: $rule.regularExpression)
                    .help("Replace with can use $1, $2… for captured groups")
            }
        case .add:
            TextField("Text", text: $rule.addText)
            Picker("Where", selection: $rule.addBefore) {
                Text("after name").tag(false)
                Text("before name").tag(true)
            }
        case .format:
            Picker("Name format", selection: $rule.format) {
                Text("Name and Index").tag(RenameRule.Format.index)
                Text("Name and Counter").tag(RenameRule.Format.counter)
                Text("Name and Date Modified").tag(RenameRule.Format.date)
            }
            TextField("Custom format", text: $rule.customName, prompt: Text("File"))
            Picker("Where", selection: $rule.numberBefore) {
                Text("after name").tag(false)
                Text("before name").tag(true)
            }
            if rule.format != .date {
                TextField("Start numbers at", value: $rule.startAt, format: .number.grouping(.never))
            }
        }
    }

    private var presetMenu: some View {
        Menu("Presets") {
            ForEach(presets) { preset in
                Button(preset.name) { rule = preset.rule }
            }
            if !presets.isEmpty { Divider() }
            Button("Save as Preset…") {
                presetName = ""
                savingPreset = true
            }
            .disabled(!rule.isActive)
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
        presets.append(RenamePreset(name: name, rule: rule))
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
