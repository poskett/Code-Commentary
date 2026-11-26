/* Declaration: Code generated using Anthropic Claude (Opus 5.5)*/
// ### Code Commentary
// All commentary below was written manually by [James Poskett](https://warwick.ac.uk/fac/arts/history/people/staff_index/poskett/) (University of Warwick).
//
// This commentary is for [v1.1.1](https://github.com/poskett/Slow-Reading-OCR/releases/tag/v1.1.1).
//
//
// ### Overview
// This script defines a job (a document which might be made up of multiple pages) ready to be sent to the OCR model.
//
// ### Import Libraries
// Here we just need CryptoKit for hashing and Foundation for basic read/write and file handling.
import CryptoKit
import Foundation

// ### Variables
// Set the app version.

public let appVersion = "1.1.1"

// Define all the variables we need to start a run.
public struct DocumentRun: Codable, Sendable {
    public var source: String
    public var sourceKind: SourceKind
    public var totalPages: Int
    public var pagesProcessed: [Int]
    public var pagesNeedingChecking: [Int]
    public var fallbackPages: [Int]
    public var model: String
    public var modelRevision: String?
    public var promptVersion: String
    public var imageLongestSide: Int
    public var temperatureByAttempt: [Float]
    public var maxTokens: Int
    public var stopOnRepetition: Bool?
    public var appVersion: String
    public var started: Date
    public var finished: Date
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
}

// ### Page Range
// A simple function to clean page ranges, normalising dashes, commas, whitespace and alike.
public func parsePageRange(_ text: String, pageCount: Int) -> [Int]? {
    var pages: [Int] = []
    var cleaned = text
    for dash in ["–", "—", "‒", "−", "‑"] {
        cleaned = cleaned.replacingOccurrences(of: dash, with: "-")
    }
    cleaned = cleaned.replacingOccurrences(of: ";", with: ",")
    for part in cleaned.split(separator: ",") {
        let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if bounds.count == 1, let page = Int(bounds[0]) {
            pages.append(page)
        } else if bounds.count == 2 {
            let first = Int(bounds[0]) ?? 1
            let last = bounds[1].isEmpty ? pageCount : (Int(bounds[1]) ?? -1)
            guard first <= last else {
                return nil
            }
            pages.append(contentsOf: first...last)
        } else {
            return nil
        }
    }
    let valid = pages.filter { $0 >= 1 && $0 <= pageCount }
    guard !valid.isEmpty else {
        return nil
    }
    var seen = Set<Int>()
    return valid.filter { seen.insert($0).inserted }
}

// ## Caching
// For a document with multiple pages, the following functions save the results of each page to a local cache. This means if the job is paused or interrupted, it can pick up from where it left off.
public func cacheDirectory(for source: PageSource, modelName: String) -> URL {
    let attributes = try? FileManager.default.attributesOfItem(atPath: source.url.path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let key = "\(source.url.standardizedFileURL.path)|\(size)|\(modified)|\(source.pageCount)|\(modelName)|\(promptVersion)"
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return ModelStore.jobsDirectory
        .appendingPathComponent(String(digest.prefix(16)), isDirectory: true)
}

// Where the cached page is.
func cachedPageURL(_ directory: URL, page: Int) -> URL {
    directory.appendingPathComponent(String(format: "page_%05d.json", page))
}

// As the function suggests, load the cached page
public func loadCachedPage(_ directory: URL, page: Int) -> PageResult? {
    guard let data = try? Data(contentsOf: cachedPageURL(directory, page: page)) else {
        return nil
    }
    
    // Decode the JSON output of the cached page
    return try? JSONDecoder().decode(PageResult.self, from: data)
}

// Save the cached page, encoding the JSON output.
public func saveCachedPage(_ result: PageResult, directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(result)
    try data.write(to: cachedPageURL(directory, page: result.page), options: .atomic)
}

// ### Page Events
// A simple enum to define events related to the page.
public enum PageEvent: Sendable {
    case started(page: Int, index: Int, total: Int)
    case attempt(PageAttempt)
    case tokens(page: Int, count: Int)
    case finished(result: PageResult, index: Int, total: Int, fromCache: Bool)
}

// ## Transcribe
// This is the core function which imports the [OCREngine](OCREngine.html) (see for details). It sends the source page to the OCR for transcription. This function also deals with the caching, picking up the saved cache where available and going from there.
public func transcribeDocument(
    engine: OCREngine,
    source: PageSource,
    pages: [Int],
    tokenLimit: Int = defaultTokenLimit,
    stopOnRepetition: Bool = true,
    onEvent: @escaping @Sendable (PageEvent) -> Void
) async throws -> (results: [PageResult], run: DocumentRun) {
    let started = Date()
    let modelName = await engine.modelName
    let cache = cacheDirectory(for: source, modelName: modelName + (await engine.modelRevision ?? ""))
    var results: [PageResult] = []

    for (index, page) in pages.enumerated() {
        try Task.checkCancellation()
        if let cached = loadCachedPage(cache, page: page),
            !(cached.needsChecking && (cached.tokenLimit ?? maxTokens) < tokenLimit)
        {
            results.append(cached)
            onEvent(.finished(result: cached, index: index, total: pages.count, fromCache: true))
            continue
        }
        onEvent(.started(page: page, index: index, total: pages.count))
        let image = try source.render(page: page)
        var result = try await engine.processPage(
            image: image, page: page, fallbackText: source.embeddedText(page: page), tokenLimit: tokenLimit,
            stopOnRepetition: stopOnRepetition
        ) { attempt in
            onEvent(.attempt(attempt))
        } onTokens: { count in
            onEvent(.tokens(page: page, count: count))
        }
        result.finishedAt = Date()
        result.tokenLimit = tokenLimit
        result.stopOnRepetition = stopOnRepetition
        try saveCachedPage(result, directory: cache)
        results.append(result)
        onEvent(.finished(result: result, index: index, total: pages.count, fromCache: false))
    }

    // When everything is done, define a DocumentRun with all the information about that run. This is returned along with the result of the OCR.
    let run = DocumentRun(
        source: source.url.path,
        sourceKind: source.kind,
        totalPages: source.pageCount,
        pagesProcessed: pages,
        pagesNeedingChecking: results.filter(\.needsChecking).map(\.page),
        fallbackPages: results.filter(\.isFallback).map(\.page),
        model: modelName,
        modelRevision: await engine.modelRevision,
        promptVersion: promptVersion,
        imageLongestSide: Int(targetLongestSide),
        temperatureByAttempt: temperatureByAttempt,
        maxTokens: tokenLimit,
        stopOnRepetition: stopOnRepetition,
        appVersion: appVersion,
        started: started,
        finished: Date(),
        totalInputTokens: results.reduce(0) { $0 + $1.inputTokens },
        totalOutputTokens: results.reduce(0) { $0 + $1.outputTokens }
    )
    return (results, run)
}
