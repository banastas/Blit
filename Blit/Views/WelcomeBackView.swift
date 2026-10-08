// The welcome-back summary's sheet (PRD R5.11): what its notification said,
// item by item. Show takes an arrival to its folder in the active pane.

import SwiftUI
import UserNotifications

struct WelcomeBackView: View {
    let summary: WelcomeBack.Summary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("While you were away").font(.title2.weight(.semibold))
                Text("Since \(summary.since.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !summary.arrived.isEmpty {
                        section("Arrived") {
                            ForEach(summary.arrived) { arrival in
                                HStack(spacing: 8) {
                                    Image(systemName: arrival.verified ? "checkmark.seal.fill" : "checkmark")
                                        .foregroundStyle(arrival.verified ? Color.green : Color.secondary)
                                        .help(arrival.verified ? "Verified by SHA-256" : "Checked by size")
                                    Text(arrival.title).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(arrival.bytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
                                    Button("Show") { show(arrival) }.controlSize(.small).disabled(arrival.items.isEmpty)
                                }
                            }
                        }
                    }
                    if !summary.fetching.isEmpty {
                        section("Fetching now") {
                            ForEach(summary.fetching.indices, id: \.self) { index in
                                let item = summary.fetching[index]
                                row(item.name, "\(Int((item.fraction * 100).rounded(.down)))%"
                                    + (item.secondsLeft.map { " · about " + TransferNotifications.duration(TimeInterval($0)) } ?? ""))
                            }
                        }
                    }
                    if !summary.downloading.isEmpty {
                        section("Still downloading in qBittorrent") {
                            ForEach(summary.downloading.indices, id: \.self) { index in
                                let item = summary.downloading[index]
                                row(item.name, "\(Int((item.fraction * 100).rounded(.down)))%")
                            }
                        }
                    }
                    if !summary.stalled.isEmpty {
                        section("Stalled while you were away") {
                            ForEach(summary.stalled.indices, id: \.self) { index in
                                let item = summary.stalled[index]
                                row(item.name, item.since.map { "since " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
                            }
                        }
                    }
                    if !summary.gaps.isEmpty {
                        section("Missing episodes") {
                            ForEach(summary.gaps, id: \.self) { Text($0) }
                        }
                    }
                    if !summary.failed.isEmpty {
                        section("Failed") {
                            ForEach(summary.failed) { arrival in
                                row(arrival.title, "open the transfer for why")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ name: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func show(_ arrival: WelcomeBack.Arrival) {
        dismiss()
        Task { await ArrivalNotifications.act(UNNotificationDefaultActionIdentifier, items: arrival.items, preview: nil) }
    }
}

/// Puts the summary's sheet on the window.
struct WelcomeBackHost: ViewModifier {
    @Bindable private var welcome = WelcomeBack.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $welcome.showing) {
            if let summary = welcome.latest { WelcomeBackView(summary: summary) }
        }
    }
}
