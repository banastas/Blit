// Blit › About Blit: the one window in the pixel-terminal style besides the HUD.

import SwiftUI

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "V\(short) · BUILD \(build)"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.none)
                .frame(width: 96, height: 96)
            Text("BLIT").font(HUDFont.label(34))
            HStack(spacing: 0) {
                Text("MOVE BIG FILES FAST. VERIFY EVERY BYTE")
                TimelineView(.periodic(from: .now, by: 0.55)) { context in
                    Text("_").opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0 ? 1 : 0)
                }
            }
            .font(HUDFont.terminal(17))
            .foregroundStyle(HUDColor.dim)
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(HUDColor.off))
                .padding(.vertical, 4)
            Text(version).font(HUDFont.terminal(20))
            // The open-source software Blit ships, with its notices and licenses
            // (the fonts' among them).
            Button { openWindow(id: "acknowledgements") } label: {
                Text("ACKNOWLEDGEMENTS ›")
                    .font(HUDFont.terminal(16))
                    .foregroundStyle(hovering ? HUDColor.bright : HUDColor.dim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("The open-source software in Blit, with its copyright notices and licenses")
        }
        .foregroundStyle(HUDColor.bright)
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: 360)
        .background(HUDColor.background)
        .environment(\.colorScheme, .dark)
    }
}
