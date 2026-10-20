// Finder-style file list (PRD R2.4–R2.6, R2.12): the AppKit list
// (FileList/NativeFileList.swift) and what goes around it: what it says
// instead of rows (no folder, an error, loading, empty, no search results),
// the path bar over its last rows, Quick Look, and the file sheets.

import QuickLook
import SwiftUI

struct FileListView: View {
    @Bindable var browser: BrowserModel
    /// The second of two panes: it starts at the same width as the first.
    var isSecondPane = false
    @AppStorage("showPathBar") private var showPathBar = true
    /// The path bar's height, kept clear under the list's rows.
    @State private var pathBarHeight: CGFloat = 24
    @AppStorage("showIconPreviews") private var showIconPreviews = true

    var body: some View {
        #if DEBUG
        let _ = UITestHarness.tick("FileListView")
        #endif
        // Always there (hidden under an error or with no folder, so the next
        // tab finds it), with what it says over it and the path bar over its
        // last rows.
        NativeFileList(browser: browser, isShown: browser.error == nil && browser.current != nil,
                       bottomInset: showPathBar && browser.current != nil ? pathBarHeight : 0,
                       iconPreviews: showIconPreviews)
            .overlay { states.allowsHitTesting(false) }
            .overlay(alignment: .topTrailing) {
                // With the path bar hidden, loading shows in the list's corner instead.
                if !showPathBar {
                    LoadingIndicator(browser: browser, floating: true)
                        .font(.system(size: 11))
                        .padding(.top, 30)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if showPathBar, browser.current != nil {
                    PathBar(browser: browser)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in pathBarHeight = height }
                }
            }
            .quickLookPreview($browser.previewURL, in: browser.previewURLs)
            .onChange(of: browser.selection) {
                // Like Finder: while Quick Look is open, it follows the selection.
                if browser.previewURL != nil { browser.previewSelection() }
            }
            .onAppear {
                // The second pane appearing: the two start at the same width.
                guard isSecondPane else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let list = FileListRegistry.scrollView(for: browser) { ColumnFit.centreDivider(from: list) }
                }
            }
            .confirmationDialog(deleteTitle, isPresented: deleteShown, presenting: browser.deleteRequest) { items in
                Button("Delete", role: .destructive) { browser.confirmDelete(items) }
                Button("Cancel", role: .cancel) {}
            } message: { items in
                Text(items.contains(where: \.isDirectory)
                     ? "This can't be undone. Folders are deleted with everything in them."
                     : "This can't be undone.")
            }
            .sheet(item: $browser.infoItem) { item in InfoView(item: item, browser: browser) }
            .sheet(isPresented: batchRenameShown) {
                if let items = browser.batchRenameItems { BatchRenameView(browser: browser, items: items) }
            }
            .sheet(isPresented: $browser.showGoToFolder) { GoToFolderView(browser: browser) }
            .sheet(isPresented: cardImportShown) {
                if let card = browser.cardImport { CardImportView(card: card, browser: browser) }
            }
            .sheet(isPresented: editBackupShown) {
                if let folders = browser.editBackupFolders { EditBackupView(folders: folders, browser: browser) }
            }
            .sheet(isPresented: watchShown) {
                if let source = browser.watchRequest { WatchSetupView(source: source, browser: browser) }
            }
    }

    @ViewBuilder private var states: some View {
        if let error = browser.error {
            ContentUnavailableView("Can't Open Folder", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if browser.current == nil {
            ContentUnavailableView("Choose a Location", systemImage: "sidebar.left")
        } else if browser.isLoading, browser.items.isEmpty {
            PixelSpinner(cell: 3)
        } else if browser.items.isEmpty {
            Text("Empty Folder").foregroundStyle(.tertiary)
        } else if !browser.searchText.trimmingCharacters(in: .whitespaces).isEmpty, browser.rows.isEmpty {
            ContentUnavailableView.search(text: browser.searchText.trimmingCharacters(in: .whitespaces))
        }
    }

    private var batchRenameShown: Binding<Bool> {
        Binding(get: { browser.batchRenameItems != nil }, set: { if !$0 { browser.batchRenameItems = nil } })
    }

    private var cardImportShown: Binding<Bool> {
        Binding(get: { browser.cardImport != nil }, set: { if !$0 { browser.cardImport = nil } })
    }

    private var editBackupShown: Binding<Bool> {
        Binding(get: { browser.editBackupFolders != nil }, set: { if !$0 { browser.editBackupFolders = nil } })
    }

    private var watchShown: Binding<Bool> {
        Binding(get: { browser.watchRequest != nil }, set: { if !$0 { browser.watchRequest = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { browser.deleteRequest != nil }, set: { if !$0 { browser.deleteRequest = nil } })
    }

    private var deleteTitle: String {
        guard let items = browser.deleteRequest else { return "" }
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
        let place = browser.current?.serverID != nil ? " from the server" : ""
        return "Delete \(what)\(place) permanently?"
    }
}
