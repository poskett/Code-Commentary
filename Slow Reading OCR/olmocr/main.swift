/* Declaration: Code generated using Anthropic Claude (Opus 5.5)*/
// ### Code Commentary
// All commentary below was written manually by [James Poskett](https://warwick.ac.uk/fac/arts/history/people/staff_index/poskett/) (University of Warwick).
//
// This commentary is for [v1.1.1](https://github.com/poskett/Slow-Reading-OCR/releases/tag/v1.1.1).
//
// ### Overview
// This is the required main.swift script for the application. It imports OlmOCRCore and runs everything.
//
// ### Import Libraries
// Here we need Foundation (to read and write to disk) and everything in OlmOCRCore to actually do the OCR.
import Foundation
import OlmOCRCore

// ### Variables and Arguments

// This defines the usage if called by command line. OlmOCRCore works irrespective of the actual application it is called in, so can be run by Terminal.
let usage = """
    usage: olmocr [options] <pdf, image or folder of images> ...

      --model <full|compact|folder>  model to use (default: the best one this Mac supports)
      --pages <range>                e.g. 1-5,9 (default: all pages)
      --out <folder>                 where to write results (default: next to each source)
      --format <list>                markdown,text,pages,jsonl,manifest (default: markdown)
      --max-tokens <n>               page length limit: 4000, 6000 (default) or 8000
      --no-repetition-check          let attempts run on when the model repeats itself (olmOCR behaviour)
      --save-images <folder>         also save each rendered page image (for checking)

    other commands:
      olmocr --check                 report what this Mac can run
      olmocr --download <full|compact>
    """

// Define the arguments, dropping the first one which is just the path of the application.
var arguments = Array(CommandLine.arguments.dropFirst())

// ### Model Tiers, Download, and Checks

// The app uses two tiers of the model, depending on how much memory is available. This defines full (8bit) and compact (4bit).
func tier(named name: String) -> ModelTier? {
    switch name {
    case "full", "8bit": return .full
    case "compact", "4bit": return .compact
    default: return nil
    }
}

// If given the check argument, then it checks whether it can run.
if arguments.first == "--check" {
    let report = checkSystem()
    print(report.diagnosticText)
    if let problem = report.blockingProblem {
        print("\nCannot run: \(problem)")
    }
    for tier in report.supportedTiers {
        let location = installedModelDirectory(tier)?.path ?? "not installed"
        print("\n\(tier.title) (\(tier.folderName)): \(location)")
        for warning in report.warnings(for: tier) {
            print("  warning: \(warning)")
        }
    }
    exit(0)
}

// Giving this argument attempts to download the model and running estimate of time left.
if arguments.first == "--download" {
    guard arguments.count == 2, let tier = tier(named: arguments[1]) else {
        print(usage)
        exit(1)
    }
    print("Downloading \(tier.repo) to \(ModelStore.modelsDirectory.path)")
    let folder = try await downloadModel(tier) { progress in
        let remaining = progress.secondsRemaining.map { String(format: ", about %.0f min left", $0 / 60) } ?? ""
        print(String(format: "  %5.1f%%  %@ of %@  %.1f MB/s%@  %@",
            progress.fraction * 100, formatBytes(progress.bytesDone), formatBytes(progress.bytesTotal),
            progress.bytesPerSecond / 1_000_000, remaining, progress.currentFile))
    }
    print("Installed in \(folder.path)")
    exit(0)
}

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

// The other main arguments
let modelChoice = option("--model") ?? checkSystem().supportedTiers.first?.rawValue ?? "compact"
let pageRange = option("--pages")
let outputFolder = option("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
let imageFolder = option("--save-images").map { URL(fileURLWithPath: $0, isDirectory: true) }
let tokenLimit = option("--max-tokens").flatMap(Int.init) ?? defaultTokenLimit
let stopOnRepetition = !arguments.contains("--no-repetition-check")
arguments.removeAll { $0 == "--no-repetition-check" }
let formatText = option("--format") ?? "markdown"
let formats = formatText.split(separator: ",").compactMap { OutputFormat(rawValue: String($0)) }

// Quit if the arguments are empty or not valid format.
guard !arguments.isEmpty, !formats.isEmpty else {
    print(usage)
    exit(1)
}

// Define the model directory and check the chosen tier of model.
var modelDirectory = URL(fileURLWithPath: modelChoice, isDirectory: true)
if let chosenTier = tier(named: modelChoice) {
    guard let installed = installedModelDirectory(chosenTier) else {
        print("The \(chosenTier.title) model is not installed. Run: olmocr --download \(chosenTier.rawValue)")
        exit(1)
    }
    modelDirectory = installed
}

// ### Load Model
// Start loading the model and print what happened.
print("Loading model \(ModelStore.modelName(for: modelDirectory)) ...")
let loadStart = Date()
let engine = try await OCREngine.load(modelDirectory: modelDirectory)
print(String(format: "Model loaded in %.1f s", Date().timeIntervalSince(loadStart)))

// ### Run the OCR
// This loop does the main OCR work, making use of everything in OlmOCRCore. It takes each argument and processes it.
for path in arguments {
    // Get the file path
    let url = URL(fileURLWithPath: path)
    // Define the page source
    let source: PageSource
    
    // Try to actually load the page source, or otherwise skip it.
    do {
        source = try PageSource(url: url)
    } catch {
        print("Skipping \(url.lastPathComponent): \(error.localizedDescription)")
        continue
    }
    // The list of pages to be processed.
    let pages: [Int]
    // Make sure the page range checks out.
    if let pageRange {
        guard let parsed = parsePageRange(pageRange, pageCount: source.pageCount) else {
            print("Skipping \(url.lastPathComponent): page range \(pageRange) does not fit its \(source.pageCount) pages.")
            continue
        }
        pages = parsed
    } else {
        pages = Array(1...source.pageCount)
    }
    // Make a note if the PDF already contained embedded text.
    if source.hasEmbeddedText() {
        print("Note: \(url.lastPathComponent) already contains a text layer; transcribing anyway.")
    }

    // Render the image and save the PNG.
    if let imageFolder {
        try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
        for page in pages {
            let image = try source.render(page: page)
            let name = url.deletingPathExtension().lastPathComponent + String(format: "_p%04d.png", page)
            try savePNG(image, to: imageFolder.appendingPathComponent(name))
        }
    }

    print("\(url.lastPathComponent): \(pages.count) of \(source.pageCount) pages")
    
    // Make the plan for OCR
    let plan = makeOutputPlan(
        source: source, outputFolder: outputFolder, formats: formats,
        model: await engine.modelName, modelRevision: await engine.modelRevision)
    
    // Call the actual function to transcribe
    let (results, run) = try await transcribeDocument(
        engine: engine, source: source, pages: pages, tokenLimit: tokenLimit,
        stopOnRepetition: stopOnRepetition
        
        // Respond to various events, such as new attempts, flagged problems, or finishing the page.
    ) { event in
        switch event {
        case .started, .tokens:
            break
        case .attempt(let attempt):
            if attempt.number > 1 {
                var line = "  p. \(attempt.page) attempt \(attempt.number) of \(attempt.total) at temperature \(attempt.temperature)"
                if attempt.rotation != 0 {
                    line += ", rotated \(attempt.rotation)°"
                }
                if let problem = attempt.previousProblem {
                    line += " (previous attempt: \(problem))"
                }
                print(line)
            }
            // What to do if finished, report whether was already done from cache, or otherwise how long it took, whether page needed rotating, and whether needs checking.
        case .finished(let result, let index, let total, let fromCache):
            var line = String(format: "  p. %d (%d/%d) ", result.page, index + 1, total)
            if fromCache {
                line += "from cache"
            } else {
                line += String(format: "%.1f s, %d tokens, attempt %d", result.seconds, result.outputTokens, result.attempts)
            }
            if result.rotation != 0 {
                line += ", rotated \(result.rotation)°"
            }
            if result.needsChecking {
                line += " NEEDS CHECKING: \(result.problem ?? "")"
            }
            print(line)
            try? writePageFile(result, source: source, plan: plan)
        }
    }
    
    // Write all the outputs of the OCR.
    let exported = try writeOutputs(results: results, run: run, source: source, plan: plan)
    for file in exported.files {
        print("  wrote \(file.path)")
    }
}
