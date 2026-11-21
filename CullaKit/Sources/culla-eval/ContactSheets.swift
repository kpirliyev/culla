import CullaAnalysis
import CullaCore
import Foundation

/// Writes the HTML pages that show each detector's results as thumbnails, worst first,
/// so a person can judge them by eye.
enum ContactSheets {
    struct Page {
        var file: String
        var title: String
        var count: Int?
        var lead: String
        var body: String
    }

    static func write(_ evaluation: Evaluation) throws {
        let builder = Builder(evaluation)
        let sheets = [
            builder.eyes(), builder.blur(), builder.stacks(),
            builder.duplicates(), builder.exposure(), builder.other(),
        ]
        let pages = [builder.index(sheets)] + sheets
        for page in pages {
            let html = document(page, navigation: pages)
            try html.write(to: evaluation.layout.page(page.file), atomically: true, encoding: .utf8)
        }
    }

    private static func document(_ page: Page, navigation: [Page]) -> String {
        let links = navigation.map { item in
            let label = item.count.map { "\(item.title) (\($0))" } ?? item.title
            let here = item.file == page.file ? " class=\"here\"" : ""
            return "<a href=\"\(item.file)\"\(here)>\(escape(label))</a>"
        }.joined()
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <title>\(escape(page.title)) · culla-eval</title>
            <style>\(style)</style>
            </head>
            <body>
            <nav>\(links)</nav>
            <h1>\(escape(page.title))</h1>
            <p class="lead">\(page.lead)</p>
            \(page.body)
            </body>
            </html>

            """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
        :root { color-scheme: dark; }
        body { margin: 0; padding: 0 20px 48px; background: #1c1c1e; color: #e5e5e7;
               font: 13px/1.45 -apple-system, "Helvetica Neue", sans-serif; }
        nav { position: sticky; top: 0; z-index: 1; display: flex; flex-wrap: wrap; gap: 18px;
              padding: 12px 0; background: #1c1c1e; border-bottom: 1px solid #3a3a3c; }
        nav a { color: #9a9aa0; text-decoration: none; }
        nav a.here { color: #fff; font-weight: 600; }
        h1 { margin: 20px 0 6px; font-size: 20px; }
        h2 { margin: 32px 0 6px; font-size: 15px; }
        h3 { margin: 0 0 6px; font-size: 12px; font-weight: 600; color: #9a9aa0; }
        p.lead, p.note { max-width: 780px; margin: 0 0 16px; color: #c7c7cc; }
        p.note { color: #9a9aa0; }
        .grid { display: flex; flex-wrap: wrap; gap: 10px; align-items: flex-start; }
        figure { margin: 0; padding: 6px; background: #2c2c2e; border-radius: 6px; }
        .pics { display: flex; gap: 4px; }
        .pics a { display: block; flex: none; }
        /* Sizes come from each img's width and height, so a tile has its final size before its
           image loads, and a focus crop is shown at one image pixel per CSS pixel. */
        .pics img { display: block; flex: none; max-width: none; border-radius: 3px; }
        figcaption { width: 0; min-width: 100%; margin-top: 5px; font-size: 11px; color: #aeaeb2; }
        figcaption b { display: block; font-size: 13px; color: #fff; }
        figcaption span { display: block; }
        figcaption .name { color: #7c7c80; word-break: break-all; }
        /* The line in a grid where a threshold falls: a row of its own, across the whole grid. */
        .divider { flex: 0 0 100%; box-sizing: border-box; padding: 8px 10px; border-top: 2px solid #e0a43a;
                   border-bottom: 2px solid #e0a43a; background: #3a2f1c; color: #f4d9a6; font-weight: 600; }
        section.group { padding: 8px; border: 1px solid #5e8f6e; border-radius: 8px; }
        section.group.near { border-color: #a08a55; }
        table { border-collapse: collapse; margin-bottom: 8px; }
        th, td { padding: 3px 20px 3px 0; text-align: left; vertical-align: top; }
        th { font-weight: 400; color: #9a9aa0; }
        code { font: 12px ui-monospace, Menlo, monospace; color: #c7c7cc; }
        li { margin-bottom: 4px; max-width: 780px; }
        """
}

private struct Builder {
    let evaluation: Evaluation
    private let timeFormat: DateFormatter
    /// Where each record's thumbnail and crops were cut, and their sizes. Nil when unreadable.
    private let previews: [Previews?]

    init(_ evaluation: Evaluation) {
        self.evaluation = evaluation
        previews = evaluation.records.indices.map { index in
            guard let scores = evaluation.records[index].scores, let summary = evaluation.summaries[index] else {
                return nil
            }
            return Previews(scores: scores, summary: summary)
        }
        timeFormat = DateFormatter()
        timeFormat.dateFormat = "HH:mm:ss.S"
    }

    private var records: [PhotoRecord] { evaluation.records }
    private var tuning: Tuning { evaluation.options.tuning }

    // MARK: - Pages

    func eyes() -> ContactSheets.Page {
        let entries = evaluation.readable
            .compactMap { index in evaluation.summaries[index]?.eyeOpenness.map { (index: index, value: $0) } }
            .sorted { $0.value < $1.value }
        let flagged = flaggedCount(entries.map(\.index), .eyesClosed)
        let rule = "eye openness below \(plain(tuning.eyesClosedBelow))"
        let unread = evaluation.readable.filter { index in
            guard let summary = evaluation.summaries[index] else { return false }
            return !summary.mainFaces.isEmpty && summary.eyeOpenness == nil
        }.count

        var body = entries.isEmpty
            ? empty("No photo has a main face with an eye reading, so there are no eyes to check.")
            : "<div class=\"grid\">"
        for (rank, entry) in entries.enumerated() {
            if rank == flagged { body += divider(flagged: flagged, shown: entries.count, what: "eyes closed", rule: rule) }
            guard let scores = records[entry.index].scores, let summary = evaluation.summaries[entry.index],
                  let worst = summary.worstEyesFace
            else { continue }
            let face = scores.faces[worst]
            let blink: String
            switch (face.blinkLeft, face.blinkRight) {
            case (true?, true?): blink = "both closed"
            case (true?, _), (_, true?): blink = "one closed"
            case (false?, false?): blink = "open"
            default: blink = "no reading"
            }
            var lines = [
                "left \(number(face.leftEyeOpenness, 2)) · right \(number(face.rightEyeOpenness, 2)) · Core Image: \(blink)",
                "turned \(number(abs(face.yawDegrees), 0))° · face \(percent(face.sizeFraction, 0)) of short side · quality \(number(face.captureQuality, 2))",
                "\(summary.mainFaces.count) of \(counted(scores.faces.count, "face", "faces")) checked",
            ]
            if face.eyesFromCrop == true { lines.append("eyes measured on a cut-out of the face") }
            body += tile(
                entry.index,
                extraImage: faceImage(entry.index),
                headline: "#\(rank + 1) · openness \(number(entry.value, 2))",
                lines: lines
            )
        }
        if !entries.isEmpty {
            if flagged == entries.count { body += divider(flagged: flagged, shown: entries.count, what: "eyes closed", rule: rule) }
            body += "</div>"
        }
        let missing = unread == 0 ? "" : " \(counted(unread, "photo has", "photos have")) a main face without an eye reading and \(unread == 1 ? "is" : "are") not shown."

        return ContactSheets.Page(
            file: "eyes.html",
            title: "Eyes closed",
            count: flagged,
            lead: """
                Every photo with an eye reading on a main face, most closed eyes first. Photos above the line \
                are flagged Eyes Closed: their most closed main face has \(rule). Each tile shows the face that \
                set the score, then the whole photo. Open eyes above the line are false alarms; shut eyes \
                below it are misses.\(missing)
                """,
            body: body
        )
    }

    func blur() -> ContactSheets.Page {
        let entries = evaluation.readable
            .compactMap { index in evaluation.summaries[index].map { (index: index, value: $0.blurScore) } }
            .sorted { $0.value < $1.value }

        let flagged = flaggedCount(entries.map(\.index), .blurry)
        let rule = "sharpness below \(plain(tuning.blurryBelow))"

        var body = entries.isEmpty ? empty("No photo could be read, so there is nothing to judge.") : "<div class=\"grid\">"
        for (rank, entry) in entries.enumerated() {
            if rank == flagged { body += divider(flagged: flagged, shown: entries.count, what: "blurry", rule: rule) }
            guard let scores = records[entry.index].scores, let summary = evaluation.summaries[entry.index] else {
                continue
            }
            let judgedOnFace = tuning.facesTakePriority && summary.faceSharpness != nil
            var lines = [
                judgedOnFace ? "judged on the sharpest face" : "judged on the subject",
                "subject \(number(scores.subjectSharpness, 1)) · frame \(number(scores.frameSharpness, 1)) · edge \(number(summary.edgeStrength, 1))",
            ]
            if let exposure = exposureLine(records[entry.index].metadata) { lines.append(exposure) }
            body += tile(
                entry.index,
                extraImage: focusImage(entry.index),
                headline: "#\(rank + 1) · sharpness \(number(entry.value, 1))",
                lines: lines
            )
        }
        if !entries.isEmpty {
            if flagged == entries.count { body += divider(flagged: flagged, shown: entries.count, what: "blurry", rule: rule) }
            body += "</div>"
        }

        return ContactSheets.Page(
            file: "blur.html",
            title: "Blurry",
            count: flagged,
            lead: """
                Every photo, softest first. Photos above the line are flagged Blurry (\(rule)). The left \
                image is the sharpest spot Culla found on the face or subject, shown at one image pixel per \
                screen pixel; if that spot is soft, the photo is soft. Sharp photos above the line are false \
                alarms; soft ones below it are misses.
                """,
            body: body
        )
    }

    func stacks() -> ContactSheets.Page {
        let order = evaluation.stacking.order
        var body = """
            <p class="note">Settings: frames join when they are at most \(number(tuning.stackGapSeconds, 1)) s \
            apart and their distance is at most \(number(tuning.stackDistance, 2)), or when the camera marked \
            them as one burst. Each tile shows its gap and distance to the photo before it. A burst that was \
            split shows as neighbours with a small gap but a distance above the limit; unrelated photos that \
            were joined show inside one green box.</p>
            """
        if evaluation.stacking.stacks.isEmpty {
            body += empty("No stacks found: no neighbouring photos were both close enough in time and alike enough.")
        }
        body += "<div class=\"grid\">"

        var position = 0
        while position < order.count {
            let index = order[position]
            if let number = evaluation.stackNumber[index] {
                var end = position
                while end + 1 < order.count, evaluation.stackNumber[order[end + 1]] == number { end += 1 }
                body += "<section class=\"group\"><h3>Stack \(number) · \(counted(end - position + 1, "frame", "frames"))</h3><div class=\"grid\">"
                for member in position...end { body += stackTile(at: member) }
                body += "</div></section>"
                position = end + 1
            } else {
                body += stackTile(at: position)
                position += 1
            }
        }
        body += "</div>"

        let stacked = evaluation.stacking.stacks.reduce(0) { $0 + $1.count }
        return ContactSheets.Page(
            file: "stacks.html",
            title: "Similar stacks",
            count: evaluation.stacking.stacks.count,
            lead: """
                \(records.count == 1 ? "The only photo" : "All \(records.count) photos") in capture order. \
                \(stackSentence(stacks: evaluation.stacking.stacks.count, photos: stacked)) Check that every box \
                is one burst or one repeated shot, and that no burst is split across boxes.
                """,
            body: body
        )
    }

    func duplicates() -> ContactSheets.Page {
        var body = ""
        for set in evaluation.duplicates {
            let label = set.kind == .exact ? "Exact copies" : "Near-duplicates"
            body += "<section class=\"group \(set.kind.rawValue)\"><h3>\(label) · \(counted(set.members.count, "file", "files"))</h3><div class=\"grid\">"
            for index in set.members {
                let record = records[index]
                let size = ByteCountFormatter.string(fromByteCount: record.file.fileSize, countStyle: .file)
                let dimensions = record.metadata.pixelWidth.flatMap { width in
                    record.metadata.pixelHeight.map { "\(width) × \($0)" }
                } ?? "size unknown"
                body += tile(index, lines: [
                    "\(size) · \(dimensions)",
                    record.metadata.captureDate.map { timeFormat.string(from: $0) } ?? "no capture time",
                ])
            }
            body += "</div></section><p></p>"
        }
        if evaluation.duplicates.isEmpty { body = "<p class=\"note\">No duplicates found.</p>" }

        return ContactSheets.Page(
            file: "duplicates.html",
            title: "Duplicates",
            count: evaluation.duplicates.count,
            lead: """
                Sets of files that hold the same photo. Exact copies have identical bytes. Near-duplicates \
                match as images (distance at most \(number(tuning.nearDuplicateDistance, 2))) but differ as \
                files, such as a resized or re-saved copy. Check that no set mixes different photos.
                """,
            body: body
        )
    }

    func exposure() -> ContactSheets.Page {
        func section(
            _ title: String,
            flag: PhotoFlag,
            threshold: Double,
            tone: String,
            _ value: (PhotoScores) -> Double
        ) -> (html: String, flagged: [Int]) {
            // From a third of the threshold up, so the photos just short of it can be compared.
            let floor = threshold / 3
            let entries = evaluation.readable
                .compactMap { index in records[index].scores.map { (index: index, value: value($0)) } }
                .filter { $0.value >= floor }
                .sorted { $0.value > $1.value }
            let flagged = entries.map(\.index).filter { evaluation.summaries[$0]?.flags.contains(flag) == true }
            let rule = "more than \(percent(threshold, 0)) of the frame clipped to \(tone)"
            var html = "<h2>\(title) · \(flagged.count) flagged</h2>"
            guard !entries.isEmpty else {
                return (html + empty("No photo is flagged: none has \(rule). No photo has even \(percent(floor, 1)) clipped to \(tone), so none is shown."), [])
            }
            html += "<div class=\"grid\">"
            for (rank, entry) in entries.enumerated() {
                if rank == flagged.count {
                    html += divider(flagged: flagged.count, shown: entries.count, what: title.lowercased(), rule: rule,
                                    below: "not flagged, down to \(percent(floor, 1)) clipped")
                }
                guard let scores = records[entry.index].scores else { continue }
                html += tile(entry.index, headline: percent(entry.value, 1), lines: [
                    "highlights \(percent(scores.clippedHighlights, 1)) · shadows \(percent(scores.clippedShadows, 1))",
                ])
            }
            if flagged.count == entries.count {
                html += divider(flagged: flagged.count, shown: entries.count, what: title.lowercased(), rule: rule)
            }
            return (html + "</div>", flagged)
        }
        let highlights = section("Clipped highlights", flag: .clippedHighlights,
                                 threshold: tuning.clippedHighlightsAbove, tone: "white", \.clippedHighlights)
        let shadows = section("Clipped shadows", flag: .clippedShadows,
                              threshold: tuning.clippedShadowsAbove, tone: "black", \.clippedShadows)

        return ContactSheets.Page(
            file: "exposure.html",
            title: "Exposure",
            count: Set(highlights.flagged + shadows.flagged).count,
            lead: """
                Photos flagged for clipping, most clipped first, followed by those with at least a third of the \
                flagging share for comparison. Highlights are flagged above \(percent(tuning.clippedHighlightsAbove, 0)) \
                of the frame at or near white, shadows above \(percent(tuning.clippedShadowsAbove, 0)) at or near \
                black. Backlit and night shots clip heavily and are often fine.
                """,
            body: highlights.html + shadows.html
        )
    }

    func other() -> ContactSheets.Page {
        var body = ""
        var total = 0

        func add(_ title: String, _ note: String, _ entries: [(index: Int, headline: String)], none: String) {
            total += entries.count
            body += "<h2>\(title) · \(entries.count)</h2><p class=\"note\">\(note)</p>"
            guard !entries.isEmpty else {
                body += empty(none)
                return
            }
            body += "<div class=\"grid\">"
            for entry in entries { body += tile(entry.index, headline: entry.headline) }
            body += "</div>"
        }

        let scored = evaluation.readable.compactMap { index in records[index].scores.map { (index: index, scores: $0) } }

        let hasAesthetics = scored.contains { $0.scores.aesthetics != nil }
        add("Low aesthetics score",
            "Vision's overall score, -1 to 1. Every photo below \(plain(tuning.lowAestheticsBelow)), lowest first; each is flagged.",
            scored.compactMap { item in item.scores.aesthetics.map { (item.index, $0) } }
                .filter { evaluation.summaries[$0.0]?.flags.contains(.lowAesthetics) == true }
                .sorted { $0.1 < $1.1 }
                .map { (index: $0.0, headline: "score \(number($0.1, 2))") },
            none: hasAesthetics
                ? "No photo has an aesthetics score below \(plain(tuning.lowAestheticsBelow))."
                : "No photo has an aesthetics score.")

        add("Utility images", "Vision's flag for screenshots, documents and similar non-photos.",
            scored.filter { $0.scores.isUtility == true }.map { (index: $0.index, headline: "utility") },
            none: "No photo is flagged as a utility image.")

        add("Lens smudge", "Vision's confidence that the lens was smudged, 0.3 and above, highest first.",
            scored.compactMap { item in item.scores.smudgeConfidence.map { (item.index, $0) } }
                .filter { $0.1 >= 0.3 }.sorted { $0.1 > $1.1 }.prefix(60)
                .map { (index: $0.0, headline: "confidence \(number($0.1, 2))") },
            none: "No photo reaches a smudge confidence of 0.3.")

        add("Tilted horizon", "Horizon angle of 2° or more, most tilted first.",
            scored.compactMap { item in item.scores.horizonDegrees.map { (item.index, $0) } }
                .filter { abs($0.1) >= 2 }.sorted { abs($0.1) > abs($1.1) }.prefix(60)
                .map { (index: $0.0, headline: "\(number($0.1, 1))°") },
            none: "No photo has a horizon tilted by 2° or more.")

        add("Face cut by the frame edge", "A main face touches the edge of the frame.",
            evaluation.readable.filter { evaluation.summaries[$0]?.hasFaceCutByEdge == true }
                .map { (index: $0, headline: "cut off") },
            none: "No main face touches the edge of the frame.")

        body += "<h2>Could not be read · \(evaluation.unreadable.count)</h2>"
        if evaluation.unreadable.isEmpty {
            body += empty("Every file could be read.")
        } else {
            body += "<ul>"
            for index in evaluation.unreadable {
                let reason = records[index].error ?? "unknown error"
                body += "<li><code>\(ContactSheets.escape(records[index].id))</code>: \(ContactSheets.escape(reason))</li>"
            }
            body += "</ul>"
        }

        return ContactSheets.Page(
            file: "other.html",
            title: "Other issues",
            count: total,
            lead: "The detectors that only flag, never reject. Check whether each list is useful enough to show in the app.",
            body: body
        )
    }

    func index(_ sheets: [ContactSheets.Page]) -> ContactSheets.Page {
        let stats = Report.stats(evaluation)
        var rows: [(String, String)] = [
            ("Folder", "<code>\(ContactSheets.escape(evaluation.options.folder.path))</code>"),
            ("Photos", "\(stats.photos)" + (stats.unreadable > 0 ? ", \(stats.unreadable) unreadable" : "")),
            ("This run", "\(stats.analysed) analysed, \(stats.reused) reused from the last run"),
        ]
        if let rate = stats.photosPerSecond {
            rows.append(("Speed", "\(number(stats.wallSeconds, 1)) s, \(number(rate, 1)) photos per second with \(evaluation.options.jobs) at once"))
        }
        rows.append(("Time per photo", "decode \(number(stats.meanDecode, 2)) s · pixel measures \(number(stats.meanPixels, 2)) s · Vision \(number(stats.meanVision, 2)) s"))
        rows.append(("Analysed at", "long side up to \(evaluation.options.maxPixelSize) px"))
        rows.append(("Photos with a main face", "\(stats.withMainFace)"))

        var body = "<table>"
        for row in rows { body += "<tr><th>\(row.0)</th><td>\(row.1)</td></tr>" }
        body += "</table>"

        body += "<h2>Flagged photos</h2><table>"
        for item in stats.flagCounts {
            let sheet = Self.sheetFile[item.flag] ?? "index.html"
            body += "<tr><th><a href=\"\(sheet)\">\(ContactSheets.escape(item.flag.label.capitalizingFirst))</a></th>"
                + "<td>\(counted(item.count, "photo", "photos"))</td></tr>"
        }
        body += "</table>"

        body += "<h2>Sheets</h2><ul>"
        for sheet in sheets {
            let count = sheet.count.map { " · \($0)" } ?? ""
            body += "<li><a href=\"\(sheet.file)\">\(ContactSheets.escape(sheet.title))</a>\(count)</li>"
        }
        body += "</ul>"

        body += """
            <h2>Settings used</h2>
            <table>
            <tr><th>Smallest face checked</th><td>\(percent(tuning.minFaceFraction, 0)) of the short side</td></tr>
            <tr><th>Background faces</th><td>under \(percent(tuning.backgroundFaceRatio, 0)) of the largest frontal face</td></tr>
            <tr><th>Profiles skipped beyond</th><td>\(number(tuning.maxYawDegrees, 0))°</td></tr>
            <tr><th>A wink counts as closed</th><td>\(tuning.countWinkAsClosed ? "yes" : "no")</td></tr>
            <tr><th>Blur judged on</th><td>\(tuning.facesTakePriority ? "the sharpest main face, else the subject" : "the subject")</td></tr>
            <tr><th>Eyes closed when eye openness is below</th><td>\(plain(tuning.eyesClosedBelow))</td></tr>
            <tr><th>Blurry when sharpness is below</th><td>\(plain(tuning.blurryBelow))</td></tr>
            <tr><th>Clipped highlights flagged above</th><td>\(percent(tuning.clippedHighlightsAbove, 0)) of the frame</td></tr>
            <tr><th>Clipped shadows flagged above</th><td>\(percent(tuning.clippedShadowsAbove, 0)) of the frame</td></tr>
            <tr><th>Low aesthetics when the score is below</th><td>\(plain(tuning.lowAestheticsBelow))</td></tr>
            <tr><th>Stack time gap</th><td>\(number(tuning.stackGapSeconds, 1)) s</td></tr>
            <tr><th>Stack distance</th><td>\(number(tuning.stackDistance, 2))</td></tr>
            <tr><th>Near-duplicate distance</th><td>\(number(tuning.nearDuplicateDistance, 2))</td></tr>
            </table>
            <h2>Processors Vision can use</h2>
            <p class="note">What Vision reports for each request. It chooses among these itself and does not \
            report which one a run used.</p>
            <ul>
            """
        for line in evaluation.deviceLines { body += "<li>\(ContactSheets.escape(line))</li>" }
        body += "</ul><p class=\"note\">All scores are also in <code>scores.csv</code>.</p>"

        return ContactSheets.Page(
            file: "index.html",
            title: "Overview",
            count: nil,
            lead: """
                Detector results for one shoot. Each sheet lists photos worst first and draws a line where its \
                threshold falls; check that the photos above the line deserve the flag and those below do not.
                """,
            body: body
        )
    }

    // MARK: - Pieces

    /// A crop shown before the thumbnail, at the given display size.
    private struct ExtraImage {
        var source: String
        var size: Previews.Size
    }

    /// The face crop, shown at the thumbnail's height so a row of tiles lines up. Nil when no
    /// face crop was cut.
    private func faceImage(_ index: Int) -> ExtraImage? {
        guard let face = previews[index]?.face else { return nil }
        return ExtraImage(source: "crops/\(evaluation.keys[index])_face.jpg", size: Previews.display(face.file))
    }

    /// The focus crop at its own pixel size, one image pixel per CSS pixel, because scaling it
    /// would hide the softness it is there to show.
    private func focusImage(_ index: Int) -> ExtraImage? {
        guard let focus = previews[index]?.focus else { return nil }
        return ExtraImage(source: "crops/\(evaluation.keys[index])_focus.jpg", size: focus.file)
    }

    private func image(_ source: String, _ size: Previews.Size) -> String {
        "<img loading=\"lazy\" src=\"\(source)\" width=\"\(size.width)\" height=\"\(size.height)\" alt=\"\">"
    }

    private func tile(_ index: Int, extraImage: ExtraImage? = nil, headline: String? = nil, lines: [String] = []) -> String {
        let record = records[index]
        var html = "<figure><div class=\"pics\">"
        if let extraImage { html += image(extraImage.source, extraImage.size) }
        if let preview = previews[index] {
            let link = ContactSheets.escape(record.file.url.absoluteString)
            let thumb = image("thumbs/\(evaluation.keys[index]).jpg", Previews.display(preview.thumbnail))
            html += "<a href=\"\(link)\">\(thumb)</a>"
        }
        html += "</div><figcaption>"
        if let headline { html += "<b>\(ContactSheets.escape(headline))</b>" }
        for line in lines { html += "<span>\(ContactSheets.escape(line))</span>" }
        html += "<span class=\"name\">\(ContactSheets.escape(record.id))</span></figcaption></figure>"
        return html
    }

    private func stackTile(at position: Int) -> String {
        let order = evaluation.stacking.order
        let index = order[position]
        var lines = [timeFormat.string(from: records[index].sortDate)
            + (records[index].metadata.captureDate == nil ? " (file date)" : "")]
        if position > 0 {
            let link = evaluation.stacking.links[position - 1]
            if link.gapSeconds <= 60 {
                let distance = link.distance.map { "distance \(number($0, 2))" } ?? "no distance"
                lines.append("+\(number(link.gapSeconds, 1)) s · \(distance) · \(link.isLinked ? "joined" : "apart")")
            }
        }
        return tile(index, lines: lines)
    }

    /// The sheet that shows each flag.
    private static let sheetFile: [PhotoFlag: String] = [
        .eyesClosed: "eyes.html", .blurry: "blur.html", .clippedHighlights: "exposure.html",
        .clippedShadows: "exposure.html", .lowAesthetics: "other.html",
    ]

    /// How many of the photos, listed worst first, carry the flag. They come first, so the
    /// divider goes after that many.
    private func flaggedCount(_ indices: [Int], _ flag: PhotoFlag) -> Int {
        indices.firstIndex { evaluation.summaries[$0]?.flags.contains(flag) != true } ?? indices.count
    }

    /// The full-width line across a grid where a threshold falls, saying what lies on each side.
    private func divider(flagged: Int, shown: Int, what: String, rule: String, below: String = "not flagged") -> String {
        let text: String
        if flagged == 0 {
            text = "No photo is flagged as \(what) (\(rule)). Below this line: \(below)."
        } else if flagged == shown {
            text = "Above this line: \(counted(flagged, "photo", "photos")) flagged as \(what) (\(rule)). Every photo shown is flagged."
        } else {
            text = "Above this line: \(counted(flagged, "photo", "photos")) flagged as \(what) (\(rule)). Below it: \(below)."
        }
        return "<div class=\"divider\">\(ContactSheets.escape(text))</div>"
    }

    /// A threshold as typed on the command line: 0.26, 25, 0.3.
    private func plain(_ value: Double) -> String {
        String(format: "%g", value)
    }

    /// The one plain line a sheet or section shows when it has nothing in it.
    private func empty(_ text: String) -> String {
        "<p class=\"note\">\(ContactSheets.escape(text))</p>"
    }

    private func stackSentence(stacks: Int, photos: Int) -> String {
        switch stacks {
        case 0: "There are no stacks."
        case 1: "One stack holds \(counted(photos, "photo", "photos")) of them, in a green box."
        default: "\(stacks) stacks hold \(photos) of them, each in a green box."
        }
    }

    private func exposureLine(_ metadata: PhotoMetadata) -> String? {
        var parts: [String] = []
        if let time = metadata.exposureTime, time > 0 {
            parts.append(time < 1 ? "1/\(Int((1 / time).rounded())) s" : "\(number(time, 1)) s")
        }
        if let aperture = metadata.fNumber { parts.append("f/\(number(aperture, 1))") }
        if let iso = metadata.iso { parts.append("ISO \(number(iso, 0))") }
        if let focal = metadata.focalLength { parts.append("\(number(focal, 0)) mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func number(_ value: Double?, _ digits: Int) -> String {
        value.map { String(format: "%.\(digits)f", $0) } ?? "–"
    }

    private func percent(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f%%", value * 100)
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
