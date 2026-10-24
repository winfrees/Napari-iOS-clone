import SwiftUI
import UniformTypeIdentifiers

/// Wraps encoded TIFF bytes for `fileExporter`.
struct TIFFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.tiff] }

    let data: Data
    let filename: String

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
        self.filename = configuration.file.filename ?? "labels"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
