import Foundation
import UniformTypeIdentifiers

/// A file someone dropped or chose, as Ferret takes it: a photo (the vision model may read it) or a document.
struct PickedFile: Identifiable, Hashable, Sendable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }

    var type: UTType? { UTType(filenameExtension: url.pathExtension.lowercased()) }

    /// "photo" for images, "document" for everything else (receipts, manuals, PDFs).
    var kind: String { type?.conforms(to: .image) == true ? "photo" : "document" }

    /// What it says it is; the server sniffs the bytes anyway and refuses what it can't keep.
    var contentType: String { type?.preferredMIMEType ?? "application/octet-stream" }

    /// Files only (no folders, no web links).
    static func from(_ urls: [URL]) -> [PickedFile] {
        urls.filter { url in
            var isFolder: ObjCBool = false
            return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && !isFolder.boolValue
        }.map(PickedFile.init)
    }
}
