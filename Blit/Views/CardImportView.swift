// Card import (PRD R5.12): a camera card's photos by day, a place for each
// day's folder, where they go on this Mac, and the NAS folder for each camera
// that backs them up. Nothing copies until Import.

import AppKit
import SwiftUI

struct CardImportView: View {
    let card: URL
    let browser: BrowserModel
    @Environment(TransferManager.self) private var transfers
    @Environment(\.dismiss) private var dismiss
    @State private var days: [CardDay]?
    @State private var read = (done: 0, of: 0)
    @State private var places: [String: String] = [:]
    /// Per day, the photos already in this Mac's folder for that day.
    @State private var imported: [String: Set<String>] = [:]
    @State private var destination = PhotoSettings.importDestination
    @State private var backUp = true
    @State private var nas = PhotoSettings.nasPhotos
    @State private var cameraFolders: [String: URL] = [:]
    @State private var nasChoices: [URL] = []

    private func newPhotos(_ day: CardDay) -> [CardPhoto] {
        let there = imported[day.day] ?? []
        return day.photos.filter { !there.contains($0.name) }
    }
    private var toImport: Int { days?.reduce(0) { $0 + newPhotos($1).count } ?? 0 }
    /// Cameras whose photos are being imported, each once.
    private var cameras: [(key: String, name: String)] {
        var seen: Set<String> = []
        return (days ?? []).filter { !newPhotos($0).isEmpty }.compactMap { day in
            seen.insert(day.cameraKey).inserted ? (day.cameraKey, day.camera.isEmpty ? "Unknown camera" : day.camera) : nil
        }
    }
    private var ready: Bool {
        destination != nil && toImport > 0 && (!backUp || cameras.allSatisfy { cameraFolders[$0.key] != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Photos from “\(card.lastPathComponent)”").font(.headline)
            Text("A folder for each day the photos were taken, named by date and the place you add. Each photo is copied and verified; the card isn't changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let days {
                if days.isEmpty {
                    Text("No photos on this card.").foregroundStyle(.secondary)
                } else {
                    dayList(days)
                    destinationRow
                    backUpRows
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(read.of == 0 ? "Reading the card…" : "Reading \(read.done) of \(read.of) photos…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(toImport == 0 ? "Import" : "Import \(toImport.formatted()) Photo\(toImport == 1 ? "" : "s")") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { await load() }
    }

    private func dayList(_ days: [CardDay]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(days) { day in
                    let new = newPhotos(day).count, there = day.photos.count - new
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.label(day.day)).fontWeight(.medium)
                            Text("\(day.photos.count) photo\(day.photos.count == 1 ? "" : "s") · \(day.bytes.formatted(.byteCount(style: .file)))\(day.camera.isEmpty ? "" : " · \(day.camera)")"
                                 + (there == 0 ? "" : new == 0 ? " · all imported already" : " · \(there) imported already"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("Place (optional)", text: Binding(get: { places[day.day] ?? "" }, set: { places[day.day] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .disabled(new == 0)
                        Text("→ " + CardImport.folderName(day: day.day, place: places[day.day] ?? ""))
                            .font(.callout.monospaced())
                            .foregroundStyle(new == 0 ? .tertiary : .secondary)
                            .frame(width: 170, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .opacity(new == 0 ? 0.6 : 1)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 260)
    }

    private var destinationRow: some View {
        HStack {
            Text("Copy to").foregroundStyle(.secondary)
            Text(destination.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "choose a folder")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(destination == nil ? "Choose…" : "Change…") {
                if let url = Self.chooseFolder(message: "Choose where shoot folders go on this Mac.", from: destination) {
                    destination = url
                    Task { await checkImported() }
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var backUpRows: some View {
        Toggle("Back up to the NAS, in the folder for each camera", isOn: $backUp)
            .font(.callout)
        if backUp {
            if nas == nil {
                HStack {
                    Text("Choose the NAS folder that holds a folder for each camera (Photographs › Digital).")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") {
                        if let url = Self.chooseFolder(message: "Choose the NAS folder that holds a folder for each camera.", from: nil) {
                            PhotoSettings.nasPhotos = url
                            nas = url
                            Task { await listCameraFolders() }
                        }
                    }
                }
            } else {
                ForEach(cameras, id: \.key) { camera in
                    HStack {
                        Text(camera.name).font(.callout)
                        Spacer()
                        Picker("", selection: Binding(get: { cameraFolders[camera.key] }, set: { url in
                            if let url { cameraFolders[camera.key] = url }
                        })) {
                            if cameraFolders[camera.key] == nil { Text("Choose its folder…").tag(URL?.none) }
                            ForEach(nasChoices, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                            if let chosen = cameraFolders[camera.key], !nasChoices.contains(chosen) {
                                Text(chosen.lastPathComponent).tag(URL?.some(chosen))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        Button("Other…") {
                            if let url = Self.chooseFolder(message: "Choose the NAS folder for \(camera.name).", from: nas) {
                                cameraFolders[camera.key] = url
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Work

    private func load() async {
        let card = card
        let found = await Task.detached(priority: .userInitiated) {
            CardImport.scan(card) { done, of in Task { @MainActor in read = (done, of) } }
        }.value
        for day in found {
            if let key = Optional(day.cameraKey), cameraFolders[key] == nil, let folder = PhotoSettings.nasFolder(forCamera: key) {
                cameraFolders[key] = folder
            }
        }
        days = found
        await checkImported()
        await listCameraFolders()
    }

    /// What's on this Mac already, per day; places from the day's folder there.
    private func checkImported() async {
        guard let destination, let days else { return }
        let found = await Task.detached {
            days.map { day -> (String, String?, Set<String>) in
                guard let existing = CardImport.existingFolder(for: day.day, in: destination) else { return (day.day, nil, []) }
                return (day.day, existing.place, CardImport.alreadyImported(day.photos, in: existing.url))
            }
        }.value
        for (day, place, there) in found {
            imported[day] = there
            if let place, (places[day] ?? "").isEmpty { places[day] = place }
        }
    }

    /// The camera folders on the NAS, to pick from.
    private func listCameraFolders() async {
        guard let nas else { return }
        nasChoices = await Task.detached {
            ((try? FileManager.default.contentsOfDirectory(at: nas, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value
    }

    private func start() {
        guard let destination, let days else { return }
        PhotoSettings.importDestination = destination
        if backUp { for (key, folder) in cameraFolders { PhotoSettings.setNASFolder(folder, forCamera: key) } }
        let plans = days.map { day in
            CardImport.Plan(day: day.day, folderName: CardImport.folderName(day: day.day, place: places[day.day] ?? ""),
                            photos: newPhotos(day), nasCamera: backUp ? cameraFolders[day.cameraKey] : nil)
        }
        if let problem = CardImport.start(plans, to: destination, transfers: transfers) {
            browser.report(problem, action: "IMPORT")
        }
        dismiss()
    }

    /// "Tue 20 Oct 2026" for "2026-10-20".
    static func label(_ day: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    static func chooseFolder(message: String, from start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        if let start { panel.directoryURL = start }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
