import Foundation
import PDFKit
import Vision
import UIKit

enum ExtractError: LocalizedError {
    case unsupported(String)
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            ext == "doc"
                ? "Old .doc files aren't supported. Save the file as .docx or PDF and try again."
                : "Files of type .\(ext) aren't supported. Use PDF, Word (.docx), an image or a text file."
        case .unreadable: "The file couldn't be read."
        case .empty: "No text was found in the document."
        }
    }
}

/// Gets plain text out of PDFs (with OCR for scans), Word files, images and text files.
/// Everything happens on the device.
enum DocumentTextExtractor {
    static func text(from url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "pdf":
            text = try await pdfText(url)
        case "docx":
            text = try docxText(url)
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "gif":
            text = try await imageText(data: Data(contentsOf: url))
        case "txt", "md", "csv":
            text = try String(contentsOf: url, encoding: .utf8)
        case "rtf":
            text = try NSAttributedString(url: url,
                                          options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil).string
        default:
            throw ExtractError.unsupported(ext)
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ExtractError.empty }
        return cleaned
    }

    static func imageText(data: Data) async throws -> String {
        guard let image = UIImage(data: data) else { throw ExtractError.unreadable }
        return try await recognize(image)
    }

    // MARK: PDF

    private static func pdfText(_ url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else { throw ExtractError.unreadable }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if embedded.count > 20 {
                pages.append(embedded)
                continue
            }
            // Scanned page without a text layer: render it and run OCR.
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0 else { continue }
            let size = CGSize(width: 1800, height: 1800 * bounds.height / bounds.width)
            let image = page.thumbnail(of: size, for: .mediaBox)
            pages.append(try await recognize(image))
        }
        return pages.joined(separator: "\n")
    }

    // MARK: Word

    private static func docxText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let xml = ZipReader.readEntry(named: "word/document.xml", from: data) else {
            throw ExtractError.unreadable
        }
        return DocxTextParser().parse(xml)
    }

    // MARK: OCR

    static func recognize(_ image: UIImage) async throws -> String {
        // Redraw so the pixel data is upright regardless of the photo's orientation flag.
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let upright = renderer.image { _ in image.draw(at: .zero) }
        guard let cgImage = upright.cgImage else { throw ExtractError.unreadable }

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            let observations = request.results ?? []
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

/// Collects the text of `word/document.xml`. Table cells are joined with tabs so "time | activity"
/// rows stay on one line.
private final class DocxTextParser: NSObject, XMLParserDelegate {
    private var text = ""
    private var inText = false
    private var tableDepth = 0

    func parse(_ data: Data) -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return text
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:t": inText = true
        case "w:tab": text += "\t"
        case "w:br": text += tableDepth > 0 ? " " : "\n"
        case "w:tbl": tableDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "w:t": inText = false
        case "w:p": text += tableDepth > 0 ? " " : "\n"
        case "w:tc": text += "\t"
        case "w:tr": text += "\n"
        case "w:tbl": tableDepth = max(0, tableDepth - 1)
        default: break
        }
    }
}
