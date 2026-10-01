// Blit › About Blit › Acknowledgements: the third-party software Blit ships,
// with each one's copyright notice and license, in the About window's
// pixel-terminal style. The text is Acknowledgements.txt in the app bundle,
// written by scripts/acknowledgements.py from the packages Blit is built with.

import SwiftUI

/// One component: "Sparkle 2.10.0", its link, copyright line and license name,
/// then its LICENSE (and NOTICE, and the licenses of code it includes).
struct Acknowledgement: Identifiable {
    let id: Int
    let title: String
    let details: [String]
    let text: String
}

enum Acknowledgements {
    /// The rule around each component's heading in Acknowledgements.txt.
    static let rule = String(repeating: "=", count: 78)

    static func load() -> [Acknowledgement] {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// The components, in the file's order: a heading between two rules, then
    /// its texts up to the next heading.
    static func parse(_ text: String) -> [Acknowledgement] {
        let lines = text.components(separatedBy: "\n")
        var items: [Acknowledgement] = []
        var index = lines.firstIndex(of: rule)
        while let start = index {
            guard let end = lines[(start + 1)...].firstIndex(of: rule) else { break }
            let heading = Array(lines[(start + 1)..<end])
            let next = lines[(end + 1)...].firstIndex(of: rule)
            let body = lines[(end + 1)..<(next ?? lines.count)].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let title = heading.first {
                items.append(Acknowledgement(id: items.count, title: title, details: Array(heading.dropFirst()), text: body))
            }
            index = next
        }
        return items
    }
}

struct AcknowledgementsView: View {
    private let items = Acknowledgements.load()
    @State private var selection = 0

    init() {
        #if DEBUG
        // -BlitAcknowledgementsSelect N: start on the Nth component (pictures, tests).
        _selection = State(initialValue: UserDefaults.standard.integer(forKey: "BlitAcknowledgementsSelect"))
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACKNOWLEDGEMENTS").font(HUDFont.label(22))
                Text("BLIT IS BUILT WITH THE OPEN-SOURCE SOFTWARE BELOW. THANK YOU TO EVERYONE WHO MADE IT.")
                    .font(HUDFont.terminal(17))
                    .foregroundStyle(HUDColor.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.top, 30)
            .padding(.bottom, 14)
            Rectangle().fill(HUDColor.border).frame(height: 1)
            if items.isEmpty {
                Text("THE ACKNOWLEDGEMENTS FILE IS MISSING FROM THIS COPY OF BLIT.")
                    .font(HUDFont.terminal(17))
                    .foregroundStyle(HUDColor.failureText)
                    .padding(22)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    list
                    Rectangle().fill(HUDColor.border).frame(width: 1)
                    detail
                }
            }
        }
        .foregroundStyle(HUDColor.bright)
        .frame(minWidth: 640, minHeight: 440)
        .background(HUDColor.background)
        .environment(\.colorScheme, .dark)
    }

    /// The components, one per row; the chosen one inverted, as in the HUD.
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Button { selection = item.id } label: {
                        Text(item.title.uppercased())
                            .font(HUDFont.terminal(17))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(item.id == selection ? HUDColor.background : HUDColor.dim)
                            .background(item.id == selection ? HUDColor.bright : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(item.id == selection ? .isSelected : [])
                }
            }
            .padding(10)
        }
        .frame(width: 230)
    }

    private var detail: some View {
        let item = items[min(selection, items.count - 1)]
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.uppercased()).font(HUDFont.label(15)).padding(.bottom, 4)
                ForEach(item.details, id: \.self) { line in
                    if let url = URL(string: line), line.hasPrefix("https://") {
                        Link(line.uppercased(), destination: url).font(HUDFont.terminal(16)).foregroundStyle(HUDColor.bright)
                    } else {
                        Text(line.uppercased()).font(HUDFont.terminal(16)).foregroundStyle(HUDColor.dim)
                    }
                }
                // The license as written: plain monospaced text, selectable.
                Text(item.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HUDColor.bright.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .id(item.id)   // a new component starts at its top
    }
}
