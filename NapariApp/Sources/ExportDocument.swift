import SwiftUI
import UniformTypeIdentifiers

/// Wraps encoded bytes (a labels TIFF or a points CSV) for `fileExporter`.
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.tiff, .commaSeparatedText] }

    let data: Data
    let filename: String
    let contentType: UTType

    init(data: Data, filename: String, contentType: UTType) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
        self.filename = configuration.file.filename ?? "export"
        self.contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
