import CullaAnalysis
import CullaCore
import CullaFiles
import Foundation

/// Everything one run produced, ready to be written out.
struct Evaluation {
    var options: Options
    var layout: OutputLayout
    var run: AnalysisRun
    var records: [PhotoRecord]
    /// One per record; nil for files that could not be analysed.
    var summaries: [PhotoSummary?]
    /// File-name-safe key of each record, naming its thumbnail and crops.
    var keys: [String]
    var stacking: Stacking
    /// Record index to 1-based stack number.
    var stackNumber: [Int: Int]
    var duplicates: [DuplicateSet]
    var deviceLines: [String]

    var readable: [Int] { records.indices.filter { records[$0].scores != nil } }
    var unreadable: [Int] { records.indices.filter { records[$0].scores == nil } }
}

@main
struct CullaEval {
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch OptionsError.help {
            print(Options.usage)
        } catch OptionsError.invalid(let message) {
            fputs("error: \(message)\n\n\(Options.usage)\n", stderr)
            exit(2)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        print("Scanning \(options.folder.path)")
        var files = try PhotoScanner.scan(folder: options.folder)
        if let limit = options.limit { files = Array(files.prefix(limit)) }
        guard !files.isEmpty else {
            print("No photos found.")
            return
        }
        let pairs = files.filter { !$0.companions.isEmpty }.count
        let pairText = pairs == 1 ? "1 of them a RAW+JPEG pair" : "\(pairs) of them RAW+JPEG pairs"
        print("  " + counted(files.count, "photo", "photos") + (pairs > 0 ? ", \(pairText)" : ""))

        let layout = OutputLayout(root: options.output)
        try layout.createFolders()

        let run = await Pipeline.run(files: files, options: options, layout: layout)
        let records = run.records
        try Pipeline.save(records, options: options, layout: layout)

        let tuning = options.tuning
        let features = records.map { $0.scores?.featureVector }
        let stacking = StackGrouper.group(
            records.indices.map { index in
                StackCandidate(
                    date: records[index].sortDate,
                    hasCaptureDate: records[index].metadata.captureDate != nil,
                    burstID: records[index].metadata.burstID,
                    feature: features[index]
                )
            },
            tuning: tuning
        )
        var stackNumber: [Int: Int] = [:]
        for (number, stack) in stacking.stacks.enumerated() {
            for index in stack { stackNumber[index] = number + 1 }
        }

        let duplicates = DuplicateFinder.find(
            records.indices.map { index in
                DuplicateCandidate(
                    fileSize: records[index].file.fileSize,
                    captureDate: records[index].metadata.captureDate,
                    feature: features[index]
                )
            },
            tuning: tuning,
            contentHash: { try? FileHasher.sha256(of: records[$0].file.url) }
        )

        let evaluation = Evaluation(
            options: options,
            layout: layout,
            run: run,
            records: records,
            summaries: records.map { $0.scores?.summary(tuning: tuning) },
            keys: records.map { FileHasher.shortKey(for: $0.id) },
            stacking: stacking,
            stackNumber: stackNumber,
            duplicates: duplicates,
            deviceLines: ComputeDeviceReport.lines()
        )

        try Report.writeCSV(evaluation)
        try ContactSheets.write(evaluation)
        print(Report.summary(evaluation))
    }
}
