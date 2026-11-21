import CullaAnalysis
import Foundation

enum OptionsError: Error {
    case help
    case invalid(String)
}

/// Command-line settings for one run.
struct Options {
    var folder: URL
    var output: URL
    var tuning = Tuning()
    /// Photos analysed at once. On an 8-core M2, throughput rises to about 27 photos per second
    /// at 4 and levels off at about 29 to 31 from 6 to 16, with the CPU half idle: Vision's own
    /// processors set the limit, not the cores. One per core, at most 8, reaches that level
    /// without holding more decoded images in memory than it gains from.
    var jobs = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    /// Long side, in pixels, of the image each photo is analysed at.
    var maxPixelSize = 4096
    var limit: Int?
    var useCache = true

    static let usage = """
        USAGE: culla-eval <folder> [options]

        Runs every Culla detector over the photos in <folder> and writes scores and
        contact sheets for judging them by eye. The folder itself is never changed.

        OUTPUT
          --out <dir>             Where to write results.
                                  Default: ./culla-eval-output/<folder name>

        FACES AND BLUR
          --min-face <0-1>        Smallest face checked, as a share of the short side. Default 0.04
          --background-ratio <r>  Faces under this share of the largest frontal face
                                  are ignored. Default 0.40
          --max-yaw <degrees>     Faces turned further than this are skipped. Default 40
          --count-winks           Treat one closed eye as closed.
          --whole-subject         Judge blur on the subject even when faces are present.

        FLAGS
          --eyes-closed-below <v> Eyes Closed when a photo's eye openness is below this.
                                  Default 0.26
          --blurry-below <v>      Blurry when the blur score is below this. Default 25
          --highlights-above <f>  Clipped highlights when more than this share of the
                                  frame, 0-1, is clipped to white. Default 0.30
          --shadows-above <f>     Clipped shadows when more than this share of the
                                  frame, 0-1, is clipped to black. Default 0.50
          --low-aesthetics-below <v>
                                  Low aesthetics when Vision's score, -1 to 1, is below
                                  this. Default 0.30
                                  Changing a flag threshold never analyses again.

        GROUPING
          --gap <seconds>         Largest time gap inside a stack. Default 10
          --similarity <d>        Largest feature distance inside a stack. Default 0.60
          --near-duplicate <d>    Largest feature distance between duplicates. Default 0.08

        RUNNING
          --jobs <n>              Photos analysed at once. Default: one per core, at most 8
          --max-pixel <n>         Long side of the analysed image. Default 4096
          --limit <n>             Only the first n photos.
          --no-cache              Analyse everything again, ignoring earlier results.
          -h, --help              Show this text.
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var folder: URL?
        var output: URL?
        var tuning = Tuning()
        var jobs: Int?
        var maxPixelSize: Int?
        var limit: Int?
        var useCache = true

        var remaining = arguments[...]
        func value(for flag: String) throws -> String {
            guard let next = remaining.popFirst() else { throw OptionsError.invalid("\(flag) needs a value") }
            return next
        }
        func number(for flag: String) throws -> Double {
            let text = try value(for: flag)
            guard let number = Double(text), number >= 0 else {
                throw OptionsError.invalid("\(flag) needs a number, not \"\(text)\"")
            }
            return number
        }
        func fraction(for flag: String) throws -> Double {
            let value = try number(for: flag)
            guard value <= 1 else { throw OptionsError.invalid("\(flag) needs a share from 0 to 1, not \(value)") }
            return value
        }
        func signedNumber(for flag: String) throws -> Double {
            let text = try value(for: flag)
            guard let number = Double(text), number.isFinite else {
                throw OptionsError.invalid("\(flag) needs a number, not \"\(text)\"")
            }
            return number
        }
        func count(for flag: String) throws -> Int {
            let text = try value(for: flag)
            guard let number = Int(text), number > 0 else {
                throw OptionsError.invalid("\(flag) needs a whole number above zero, not \"\(text)\"")
            }
            return number
        }

        while let argument = remaining.popFirst() {
            switch argument {
            case "-h", "--help": throw OptionsError.help
            case "--out": output = URL(fileURLWithPath: try value(for: argument))
            case "--min-face": tuning.minFaceFraction = try number(for: argument)
            case "--background-ratio": tuning.backgroundFaceRatio = try number(for: argument)
            case "--max-yaw": tuning.maxYawDegrees = try number(for: argument)
            case "--count-winks": tuning.countWinkAsClosed = true
            case "--whole-subject": tuning.facesTakePriority = false
            case "--eyes-closed-below": tuning.eyesClosedBelow = try number(for: argument)
            case "--blurry-below": tuning.blurryBelow = try number(for: argument)
            case "--highlights-above": tuning.clippedHighlightsAbove = try fraction(for: argument)
            case "--shadows-above": tuning.clippedShadowsAbove = try fraction(for: argument)
            case "--low-aesthetics-below": tuning.lowAestheticsBelow = try signedNumber(for: argument)
            case "--gap": tuning.stackGapSeconds = try number(for: argument)
            case "--similarity": tuning.stackDistance = try number(for: argument)
            case "--near-duplicate": tuning.nearDuplicateDistance = try number(for: argument)
            case "--jobs": jobs = try count(for: argument)
            case "--max-pixel": maxPixelSize = try count(for: argument)
            case "--limit": limit = try count(for: argument)
            case "--no-cache": useCache = false
            default:
                guard !argument.hasPrefix("-") else { throw OptionsError.invalid("Unknown option \(argument)") }
                guard folder == nil else { throw OptionsError.invalid("Only one folder can be given") }
                folder = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
            }
        }

        guard let folder else { throw OptionsError.invalid("No folder given") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OptionsError.invalid("\(folder.path) is not a folder")
        }

        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        let defaultOutput = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("culla-eval-output")
            .appendingPathComponent(resolved.lastPathComponent)
        var options = Options(folder: resolved, output: (output ?? defaultOutput).standardizedFileURL)
        options.tuning = tuning
        if let jobs { options.jobs = jobs }
        if let maxPixelSize { options.maxPixelSize = maxPixelSize }
        options.limit = limit
        options.useCache = useCache
        return options
    }
}

/// Where each kind of result file lives inside the output folder.
struct OutputLayout {
    var root: URL

    var scoresJSON: URL { root.appendingPathComponent("scores.json") }
    var scoresCSV: URL { root.appendingPathComponent("scores.csv") }
    var thumbs: URL { root.appendingPathComponent("thumbs") }
    var crops: URL { root.appendingPathComponent("crops") }

    func thumb(_ key: String) -> URL { thumbs.appendingPathComponent("\(key).jpg") }
    func faceCrop(_ key: String) -> URL { crops.appendingPathComponent("\(key)_face.jpg") }
    func focusCrop(_ key: String) -> URL { crops.appendingPathComponent("\(key)_focus.jpg") }

    func page(_ name: String) -> URL { root.appendingPathComponent(name) }

    func createFolders() throws {
        for folder in [root, thumbs, crops] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}
