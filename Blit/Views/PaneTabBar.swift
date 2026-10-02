// The tab bar (R2.18): one tab per pair of panes, above the cards in the same
// gutter. Names stay in the system font; the pixel look marks what the
// keyboard and the transfers say: each tab's ⌘-number, and a small HUD tag
// while a transfer touches one of the tab's folders.

import SwiftUI

struct PaneTabBar: View {
    let twoPanes: Bool
    @Environment(ServerStore.self) private var servers
    @Environment(TransferManager.self) private var transfers
    /// The tab being dragged along the bar.
    @State private var drag: TabDrag?

    struct TabDrag: Equatable {
        let id: UUID
        /// Where the tab was grabbed, from its left edge.
        let grab: CGFloat
        /// The pointer, in the row's coordinates.
        var pointer: CGFloat
    }

    private static let spacing: CGFloat = 4
    static let height: CGFloat = 33
    /// Tabs are at most this wide and sit at the left: tabs as wide as the
    /// panes lined up with them and read as the panes' headers. Many tabs
    /// share the bar, down to the minimum.
    private static let maxTabWidth: CGFloat = 220
    private static let minTabWidth: CGFloat = 100
    /// The row of tabs' own coordinates (x 0 is the first tab's left edge),
    /// which stay put while tabs change places under a drag.
    private static let row = "tabRow"

    /// The tabs' width in a bar `width` wide: tabs, gaps, the + button and the
    /// padding fill it exactly, down to the minimum. From the width the bar is
    /// given, never its own: a row wider than the bar used to widen the bar,
    /// so the tabs never shrank and pushed the window's panes off its edges.
    static func tabWidth(barWidth: CGFloat, count: Int) -> CGFloat {
        let count = CGFloat(max(count, 1))
        let room = barWidth - 16 - 24 - spacing * count   // the side padding, the + button, the gaps
        return min(maxTabWidth, max(minTabWidth, (room / count).rounded(.down)))
    }

    /// The slot a dragged tab goes to: the one its left edge is nearest, with
    /// the pointer at `pointer` holding it `grab` from that edge. Past either
    /// end of the row is the first or last slot.
    static func slot(pointer: CGFloat, grab: CGFloat, step: CGFloat, count: Int) -> Int {
        guard count > 0, step > 0 else { return 0 }
        return min(max(Int(((pointer - grab) / step).rounded()), 0), count - 1)
    }

    var body: some View {
        GeometryReader { proxy in
            // Once a second, as the strip does: a transfer's byte count isn't observed.
            TimelineView(.periodic(from: .now, by: 1)) { _ in bar(width: proxy.size.width) }
        }
        .frame(height: Self.height)
    }

    private func bar(width: CGFloat) -> some View {
        let tabs = PaneTabs.shared
        let tabWidth = Self.tabWidth(barWidth: width, count: tabs.tabs.count)
        let step = tabWidth + Self.spacing
        return HStack(spacing: Self.spacing) {
            ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                PaneTabItem(tab: tab, index: index, isSelected: tab.id == tabs.current?.id,
                            title: tab.title(twoPanes: twoPanes, servers: servers),
                            detail: detail(tab), activity: activity(tab))
                    .frame(width: tabWidth)
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _, frame in
                        UITestHarness.tabFrames[tab.id] = frame
                    }
                    #endif
                    .offset(x: offset(of: tab.id, at: index, step: step, count: tabs.tabs.count))
                    .zIndex(drag?.id == tab.id ? 1 : 0)
                    // The others slide to make room; the dragged tab stays under the pointer.
                    .transaction { if drag?.id == tab.id { $0.animation = nil } }
                    .gesture(reorder(tab, step: step))
            }
            Button {
                PaneTabs.shared.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab (⌘T)")
            .accessibilityLabel("New tab")
        }
        .coordinateSpace(.named(Self.row))
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .clipped()
        .background(Color.black.opacity(0.10))
    }

    /// The dragged tab follows the pointer, kept within the row; the others
    /// sit in their slots.
    private func offset(of id: UUID, at index: Int, step: CGFloat, count: Int) -> CGFloat {
        guard let drag, drag.id == id else { return 0 }
        let left = min(max(drag.pointer - drag.grab, 0), CGFloat(max(count - 1, 0)) * step)
        return left - CGFloat(index) * step
    }

    /// Drag a tab along the bar: it follows the pointer and takes the slot it's
    /// over, however far and fast it goes. Measured in the row's coordinates,
    /// which don't move as the tab changes places. (It used to measure from
    /// the tab itself and trade places one neighbour per mouse event, so fast
    /// drags fell short of the ends.)
    private func reorder(_ tab: PaneTab, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.row))
            .onChanged { value in
                let tabs = PaneTabs.shared
                if drag?.id != tab.id {
                    guard let index = tabs.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                    drag = TabDrag(id: tab.id, grab: value.startLocation.x - CGFloat(index) * step, pointer: value.location.x)
                    tabs.select(tab.id)
                }
                drag?.pointer = value.location.x
                guard let drag else { return }
                let target = Self.slot(pointer: drag.pointer, grab: drag.grab, step: step, count: tabs.tabs.count)
                if target != tabs.tabs.firstIndex(where: { $0.id == tab.id }) {
                    withAnimation(.snappy(duration: 0.18)) { tabs.move(tab.id, to: target) }
                }
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) { drag = nil }
            }
    }

    /// The tab's full paths, for its tooltip.
    private func detail(_ tab: PaneTab) -> String {
        let paths = [tab.first.current.map { _ in tab.first.subtitle },
                     twoPanes ? tab.second?.current.map { _ in tab.second?.subtitle ?? "" } : nil]
        return paths.compactMap { $0 }.joined(separator: "  ·  ")
    }

    /// The HUD tag for the transfer touching one of `tab`'s folders (a pane
    /// showing its destination or where its files come from, or inside them):
    /// ▼ 42% while it runs, ‖ paused, then ✓ or ✕. A running one wins.
    private func activity(_ tab: PaneTab) -> PaneTabItem.Activity? {
        let shown = [tab.firstLocation, twoPanes ? tab.secondLocation : nil].compactMap { $0 }
        guard !shown.isEmpty else { return nil }
        let touching = transfers.jobs.filter { job in
            guard !job.isOperation else { return false }
            let places = [BrowseLocation.local(job.destination)] + job.sources + job.sources.compactMap(\.parent)
            return shown.contains { pane in
                // By the paths alone: this runs every second on the main thread.
                places.contains { place in pane == place || FileOperations.location(place, textuallyContains: pane) }
            }
        }
        if let running = touching.last(where: \.isActive) {
            let percent = Int((running.progress * 100).rounded())   // as the strip and HUD round
            return .init(text: "\(running.directionGlyph) \(percent)%", failed: false,
                         label: "Transfer \(percent) percent")
        }
        guard let job = touching.last else { return nil }
        if job.status == .paused { return .init(text: "‖", failed: false, label: "Transfer paused") }
        if job.status != .finished || !job.failures.isEmpty || job.notice != nil {
            return job.status == .queued ? nil : .init(text: "✕", failed: true, label: "Transfer failed")
        }
        return .init(text: "✓", failed: false, label: "Transfer done")
    }
}

private struct PaneTabItem: View {
    struct Activity: Equatable {
        var text: String
        var failed: Bool
        var label: String
    }

    let tab: PaneTab
    let index: Int
    let isSelected: Bool
    let title: String
    let detail: String
    let activity: Activity?
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { PaneTabs.shared.renamingID == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            leading
            Group {
                if isRenaming {
                    TextField("Tab Name", text: $draft)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .focused($fieldFocused)
                        .onSubmit { PaneTabs.shared.rename(tab.id, to: draft) }
                        .onExitCommand { PaneTabs.shared.renamingID = nil }
                        .onChange(of: fieldFocused) { _, focused in
                            if !focused, isRenaming { PaneTabs.shared.rename(tab.id, to: draft) }
                        }
                        .onAppear {
                            draft = tab.customName ?? title
                            Task { fieldFocused = true }
                        }
                } else {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            if let activity {
                hudText(activity.text, glyphSize: 9)
                    .font(HUDFont.terminal(15))
                    .foregroundStyle(activity.failed ? HUDColor.failureText : HUDColor.bright)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
                    .accessibilityLabel(activity.label)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor)
                      : hovering ? Color.primary.opacity(0.06) : Color.clear)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // A double-click names the tab (the first click has already chosen it).
            if NSApp.currentEvent?.clickCount == 2 {
                PaneTabs.shared.renamingID = tab.id
            } else {
                PaneTabs.shared.select(tab.id)
            }
        }
        .help(detail)
        .contextMenu {
            Button("New Tab") { PaneTabs.shared.newTab() }
            Divider()
            Button("Rename Tab…") {
                PaneTabs.shared.select(tab.id)
                PaneTabs.shared.renamingID = tab.id
            }
            if tab.customName != nil {
                Button("Name After Folders") { PaneTabs.shared.rename(tab.id, to: "") }
            }
            Divider()
            Button("Close Tab") { PaneTabs.shared.close(tab.id) }
            Button("Close Other Tabs") { PaneTabs.shared.closeOthers(than: tab.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Tab \(index + 1)")
    }

    /// The tab's ⌘-number in the HUD's pixel face (a black chip on the shown
    /// tab); hovering turns it into the close button.
    @ViewBuilder private var leading: some View {
        if hovering, !isRenaming {
            Button {
                PaneTabs.shared.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 16)
                    .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close Tab (⌘W)")
            .accessibilityLabel("Close tab")
        } else if index < 9 {
            Text(String(format: "%02d", index + 1))
                .font(HUDFont.label(8))
                .foregroundStyle(isSelected ? HUDColor.bright : Color.secondary)
                .frame(width: 18, height: 16)
                .background(isSelected ? HUDColor.background : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .help("⌘\(index + 1)")
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 18, height: 16)
        }
    }
}
