// The file list for one folder: loading off the main thread, sorting (newest
// first by default, PRD R2.4), and back/forward history.

import Foundation
import Observation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var modified: Date
    /// -1 for folders, so they sort below files by size.
    var size: Int64
    var kind: String
    var id: URL { url }
}

@MainActor
@Observable
final class BrowserModel {
    private(set) var current: URL?
    private(set) var items: [FileItem] = []
    private(set) var error: String?
    private(set) var isLoading = false
    var sortOrder = [KeyPathComparator(\FileItem.modified, order: .reverse)]

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    var sortedItems: [FileItem] { items.sorted(using: sortOrder) }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { current.map { $0.path != "/" } ?? false }

    func open(_ url: URL) {
        guard url != current else { return }
        if let current { backStack.append(current) }
        forwardStack.removeAll()
        show(url)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current { forwardStack.append(current) }
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current { backStack.append(current) }
        show(next)
    }

    func goUp() {
        guard let current, canGoUp else { return }
        open(current.deletingLastPathComponent())
    }

    func reload() {
        guard let current else { return }
        show(current)
    }

    private func show(_ url: URL) {
        current = url
        isLoading = true
        Task {
            do {
                let listed = try await Task.detached { try Self.list(url) }.value
                guard url == current else { return }
                items = listed
                error = nil
            } catch {
                guard url == current else { return }
                items = []
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    nonisolated static func list(_ folder: URL) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey,
                                      .localizedTypeDescriptionKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isFolder = (v.isDirectory ?? false) && !(v.isPackage ?? false)
            return FileItem(url: url, name: url.lastPathComponent, isDirectory: isFolder,
                            modified: v.contentModificationDate ?? .distantPast,
                            size: isFolder ? -1 : Int64(v.fileSize ?? 0),
                            kind: v.localizedTypeDescription ?? (isFolder ? "Folder" : "Document"))
        }
    }
}
