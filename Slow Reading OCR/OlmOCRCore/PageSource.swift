/* Declaration: Code generated using Anthropic Claude (Opus 5.5)*/
// ### Code Commentary
// All commentary below was written manually by [James Poskett](https://warwick.ac.uk/fac/arts/history/people/staff_index/poskett/) (University of Warwick).
//
// This commentary is for [v1.1.1](https://github.com/poskett/Slow-Reading-OCR/releases/tag/v1.1.1).
//
// ### Overview
// This script defines functions to inspect, read, and present the actual PDF or image file used in the OCR.
//
// ### Import Libraries
// Alongside core libraries like CoreImage and Foundation, we also need PDFKit to extract and handle PDFs.
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// ### Variables
// olmOCR 2 needs a specific longest side length, defined here.
public let targetLongestSide: CGFloat = 1288

// Define an enum for different kinds of problems with the source.
public enum PageSourceError: LocalizedError {
    case unreadable(URL)
    case encrypted(URL)
    case noPages(URL)
    case unsupported(URL)
    case pageOutOfRange(Int)
    case renderFailed(Int)

    // The enum includes the error descriptions.
    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Could not open \(url.lastPathComponent). The file may be damaged."
        case .encrypted(let url): return "\(url.lastPathComponent) is password-protected."
        case .noPages(let url):
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isFolder
                ? "\(url.lastPathComponent) has no images or PDFs in it."
                : "\(url.lastPathComponent) has no pages."
        case .unsupported(let url): return "\(url.lastPathComponent) is not a PDF or an image file."
        case .pageOutOfRange(let page): return "Page \(page) does not exist."
        case .renderFailed(let page): return "Page \(page) could not be rendered."
        }
    }
}

// A simple enum to define what kind of source we're looking at: a pdf, image, or a folder full of files.
public enum SourceKind: String, Codable, Sendable {
    case pdf
    case image
    case folder
}

// ### Page Class and Functions
// A class to define everything about the page.
public final class PageSource: @unchecked Sendable {
    public let url: URL
    public let kind: SourceKind
    public let pageCount: Int
    private let pdf: PDFDocument?
    private let imageSource: CGImageSource?
    public let imageFiles: [URL]
    public let pageStems: [String]

    // Define the supported file types
    public static let supportedExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "tif", "tiff", "jp2", "j2k", "jpf", "heic", "heif", "gif", "bmp", "webp",
    ]

    // Define if it is password protected
    public init(url: URL, password: String? = nil) throws {
        self.url = url
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let files = PageSource.imageFiles(in: url)
            guard !files.isEmpty else {
                throw PageSourceError.noPages(url)
            }
            self.kind = .folder
            self.pdf = nil
            self.imageSource = nil
            self.imageFiles = files
            self.pageStems = PageSource.uniqueStems(files, reserved: url.lastPathComponent)
            self.pageCount = files.count
            return
        }
        self.imageFiles = []
        self.pageStems = []
        let ext = url.pathExtension.lowercased()
        // Throw an error if an unsupported file type
        guard PageSource.supportedExtensions.contains(ext) else {
            throw PageSourceError.unsupported(url)
        }
        // If it is a PDF, check can read it or throw an error.
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else {
                throw PageSourceError.unreadable(url)
            }
            // If is a PDF and locked, see if can unlock, if not, throw error.
            if document.isLocked {
                if let password, document.unlock(withPassword: password) {
                } else {
                    throw PageSourceError.encrypted(url)
                }
            }
            // If it is a PDF, check the document has some pages!
            guard document.pageCount > 0 else {
                throw PageSourceError.noPages(url)
            }
            self.kind = .pdf
            self.pdf = document
            self.imageSource = nil
            self.pageCount = document.pageCount
        } else {
            // If a kind of image file, check it is readable.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw PageSourceError.unreadable(url)
            }
            // And likewise check it has >0 pages.
            let count = CGImageSourceGetCount(source)
            guard count > 0 else {
                throw PageSourceError.noPages(url)
            }
            self.kind = .image
            self.pdf = nil
            self.imageSource = source
            self.pageCount = count
        }
    }

    //A function to return any embedded text in the PDF.
    public func embeddedText(page: Int) -> String? {
        guard let pdf, let pdfPage = pdf.page(at: page - 1) else {
            return nil
        }
        let text = pdfPage.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // A function to simply check if a PDF and has embedded text.
    public func hasEmbeddedText(samplePages: Int = 3) -> Bool {
        guard kind == .pdf else {
            return false
        }
        for page in 1...min(samplePages, pageCount) {
            if let text = embeddedText(page: page), text.count > 200 {
                return true
            }
        }
        return false
    }

    // ### Rendering
    // This function renders the actual page as an image so it can be sent to the OCR later. It mainly just calls the relevant renderPDFPage or renderImage which handles the actual processing.
    public func render(page: Int, longestSide: CGFloat = targetLongestSide) throws -> CIImage {
        guard page >= 1, page <= pageCount else {
            throw PageSourceError.pageOutOfRange(page)
        }
        switch kind {
        case .pdf:
            return try renderPDFPage(page, longestSide: longestSide)
        case .image:
            guard let imageSource else {
                throw PageSourceError.renderFailed(page)
            }
            return try renderImage(from: imageSource, index: page - 1, page: page, longestSide: longestSide)
        case .folder:
            guard let source = CGImageSourceCreateWithURL(imageFiles[page - 1] as CFURL, nil) else {
                throw PageSourceError.renderFailed(page)
            }
            return try renderImage(from: source, index: 0, page: page, longestSide: longestSide)
        }
    }

    public func pageLabel(_ page: Int) -> String {
        kind == .folder ? imageFiles[page - 1].lastPathComponent : "\(page)"
    }

    public static func imageFiles(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) && $0.pathExtension.lowercased() != "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
// This checks the page stems, although probably not strictly necessary as that is done in [Exporters.html](Exporters.swift).
    static func uniqueStems(_ files: [URL], reserved: String) -> [String] {
        let stems = files.map { $0.deletingPathExtension().lastPathComponent }
        var counts: [String: Int] = [:]
        for stem in stems {
            counts[stem.lowercased(), default: 0] += 1
        }
        var used: Set<String> = [reserved.lowercased()]
        var unique: [String] = []
        for (file, stem) in zip(files, stems) {
            var name = counts[stem.lowercased()] == 1 ? stem : file.lastPathComponent
            if name.lowercased() == reserved.lowercased() {
                name += "_page"
            }
            let first = name
            var number = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(first)_\(number)"
                number += 1
            }
            unique.append(name)
        }
        return unique
    }

    // This is the function to do the rendering of the image from each PDF page. It uses PDFKit.
    private func renderPDFPage(_ page: Int, longestSide: CGFloat) throws -> CIImage {
        guard let pdf, let pdfPage = pdf.page(at: page - 1) else {
            throw PageSourceError.renderFailed(page)
        }
        // Calculate the bounding box, width, height, and scale.
        let box = pdfPage.bounds(for: .mediaBox)
        let quarterTurns = ((pdfPage.rotation % 360) + 360) % 360 / 90
        let pageWidth = quarterTurns % 2 == 0 ? box.width : box.height
        let pageHeight = quarterTurns % 2 == 0 ? box.height : box.width
        let scale = longestSide / max(pageWidth, pageHeight)
        let pixelWidth = Int((pageWidth * scale).rounded())
        let pixelHeight = Int((pageHeight * scale).rounded())

        // Define the image space using the above so we can draw.
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            throw PageSourceError.renderFailed(page)
        }
        // Fill the empty image with white
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(pdfPage.transform(for: .mediaBox))
        // Draw the actual PDF page to the image.
        pdfPage.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else {
            throw PageSourceError.renderFailed(page)
        }
        return CIImage(cgImage: cgImage)
    }

    // The same idea again, but this time for image files rather than PDFs. This is a bit more straightforward, because we don't need to extract the image from the PDF. We can just decode, apply the relevant metadata (exif) and resize.
    private func renderImage(from imageSource: CGImageSource, index: Int, page: Int, longestSide: CGFloat) throws -> CIImage {
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else {
            throw PageSourceError.renderFailed(page)
        }
        var image = CIImage(cgImage: cgImage)
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any]
        if let orientation = properties?[kCGImagePropertyOrientation] as? UInt32,
            let exif = CGImagePropertyOrientation(rawValue: orientation), exif != .up
        {
            image = image.oriented(exif)
            image = image.transformed(
                by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        }
        return resize(image, longestSide: longestSide)
    }
}

// ### Resize
// olmOCR 2 requires a specific longest side size of the image, so this function (called above) makes sure we resize the image correctly.
public func resize(_ image: CIImage, longestSide: CGFloat) -> CIImage {
    let longest = max(image.extent.width, image.extent.height)
    if longest == longestSide {
        return image
    }
    let filter = CIFilter(name: "CILanczosScaleTransform")!
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(longestSide / longest, forKey: kCIInputScaleKey)
    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
    return filter.outputImage!
}

// Likewise, this allows for rotation as needed, particularly for retries.
public func rotateCounterClockwise(_ image: CIImage, degrees: Int) -> CIImage {
    let normalised = ((degrees % 360) + 360) % 360
    if normalised == 0 {
        return image
    }
    let radians = CGFloat(normalised) * .pi / 180
    let rotated = image.transformed(by: CGAffineTransform(rotationAngle: radians))
    return rotated.transformed(
        by: CGAffineTransform(translationX: -rotated.extent.origin.x, y: -rotated.extent.origin.y))
}

// A simple function to save the image we created as an actual .png file.
public func savePNG(_ image: CIImage, to url: URL) throws {
    let context = CIContext()
    try context.writePNGRepresentation(
        of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}
