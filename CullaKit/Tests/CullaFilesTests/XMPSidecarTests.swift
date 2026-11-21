import CullaCore
@testable import CullaFiles
import Foundation
import Testing

/// Sidecars shaped like the ones real editors write, built from what is known of their format.
enum SampleSidecars {
    /// Like Lightroom Classic and Camera Raw: no xpacket wrapper, one rdf:Description holding
    /// simple properties as attributes and structured ones as child elements.
    static let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmlns:aux="http://ns.adobe.com/exif/1.0/aux/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
            xmlns:stEvt="http://ns.adobe.com/xap/1.0/sType/ResourceEvent#"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           tiff:Make="Canon"
           tiff:Model="Canon EOS R5"
           exif:ExposureTime="1/250"
           exif:FNumber="28/10"
           xmp:ModifyDate="2026-11-08T14:22:31+01:00"
           xmp:CreatorTool="Adobe Photoshop Lightroom Classic 14.0 (Macintosh)"
           xmp:Rating="2"
           xmp:Label="Yellow"
           aux:Lens="RF24-70mm F2.8 L IS USM"
           photoshop:DateCreated="2026-11-08T11:02:15.43"
           xmpMM:DocumentID="xmp.did:6f6d3a8e-1d2b-4b9a-9b1e-2f1c0b8a7d61"
           crs:Version="17.0"
           crs:ProcessVersion="15.4"
           crs:WhiteBalance="As Shot"
           crs:Exposure2012="+0.35"
           crs:HasSettings="True">
           <dc:subject>
            <rdf:Bag>
             <rdf:li>wedding</rdf:li>
             <rdf:li>ceremony &amp; vows</rdf:li>
            </rdf:Bag>
           </dc:subject>
           <xmpMM:History>
            <rdf:Seq>
             <rdf:li
              stEvt:action="saved"
              stEvt:instanceID="xmp.iid:0b1c2d3e"
              stEvt:when="2026-11-08T14:22:31+01:00"
              stEvt:softwareAgent="Adobe Photoshop Lightroom Classic 14.0 (Macintosh)"
              stEvt:changed="/metadata"/>
            </rdf:Seq>
           </xmpMM:History>
           <crs:ToneCurvePV2012>
            <rdf:Seq>
             <rdf:li>0, 0</rdf:li>
             <rdf:li>255, 255</rdf:li>
            </rdf:Seq>
           </crs:ToneCurvePV2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """

    /// Like Capture One's synced sidecars: an xpacket wrapper with a byte-order mark in `begin`,
    /// properties as attributes, IPTC and Dublin Core structures as elements, and padding.
    static let captureOne = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" + """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
           <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
                    xmlns:dc="http://purl.org/dc/elements/1.1/"
                    xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/">
                 <xmp:Rating>4</xmp:Rating>
                 <xmp:Label>Purple</xmp:Label>
                 <photoshop:City>Lisbon</photoshop:City>
                 <dc:creator>
                    <rdf:Seq>
                       <rdf:li>Kamran</rdf:li>
                    </rdf:Seq>
                 </dc:creator>
                 <Iptc4xmpCore:Location>Belém</Iptc4xmpCore:Location>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        """ + "\n" + String(repeating: " ", count: 400) + "\n<?xpacket end=\"w\"?>"

    /// Like exiftool's output: single quotes, one rdf:Description per namespace, element form,
    /// an unknown namespace and comments.
    static let severalDescriptions = """
        <?xml version='1.0' encoding='UTF-8'?>
        <!-- written by some tool -->
        <x:xmpmeta xmlns:x='adobe:ns:meta/' x:xmptk='Image::ExifTool 12.76'>
        <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>

         <rdf:Description rdf:about=''
          xmlns:tiff='http://ns.adobe.com/tiff/1.0/'>
          <tiff:Make>NIKON CORPORATION</tiff:Make>
          <!-- keep me -->
         </rdf:Description>

         <rdf:Description rdf:about=''
          xmlns:xap='http://ns.adobe.com/xap/1.0/'>
          <xap:Rating>5</xap:Rating>
         </rdf:Description>

         <rdf:Description rdf:about=''
          xmlns:zz='http://example.com/unknown/1.0/'>
          <zz:Thing zz:attr='x'><zz:Inner>deep</zz:Inner></zz:Thing>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
}

private func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// The text of `edited` with every occurrence of the listed replacements undone, to compare
/// with the original: proves that nothing but those spans changed.
private func reverting(_ edited: String, _ replacements: [(String, String)]) -> String {
    var text = edited
    for (original, written) in replacements {
        text = text.replacingOccurrences(of: written, with: original)
    }
    return text
}

@Suite("XMP sidecars")
struct XMPSidecarTests {
    @Test(arguments: SidecarDecision.allCases, [0, 1, 3, 5])
    func freshSidecarsReadBack(decision: SidecarDecision, rating: Int) throws {
        let mark = SidecarMark(decision: decision, rating: rating)
        let data = XMPSidecar.fresh(mark: mark)
        let fields = try XMPSidecar.read(data)
        #expect(fields.mark == mark)
        #expect(fields.decision == decision)
        #expect(fields.cullaRating == rating)
        switch decision {
        case .rejected:
            #expect(fields.rating == -1)
            #expect(fields.label == "Red")
        case .kept:
            #expect(fields.rating == (rating > 0 ? rating : nil))
            #expect(fields.label == "Green")
        case .unreviewed:
            #expect(fields.rating == (rating > 0 ? rating : nil))
            #expect(fields.label == nil)
        }
        // It is valid XML, and has the shape Lightroom writes: no xpacket, attribute form.
        #expect(XMLParser(data: data).parse())
        #expect(!string(data).contains("xpacket"))
        #expect(string(data).hasPrefix("<x:xmpmeta"))
    }

    @Test func theMappingIsConfigurable() throws {
        var mapping = SidecarMapping()
        mapping.keptLabel = nil
        mapping.rejectedLabel = "Purple"
        mapping.rejectedRating = nil
        let kept = try XMPSidecar.read(XMPSidecar.fresh(mark: SidecarMark(decision: .kept, rating: 2), mapping: mapping))
        #expect(kept.label == nil && kept.rating == 2 && kept.decision == .kept)
        let rejected = try XMPSidecar.read(XMPSidecar.fresh(mark: SidecarMark(decision: .rejected, rating: 2), mapping: mapping))
        #expect(rejected.label == "Purple" && rejected.rating == nil && rejected.cullaRating == 2)
        mapping.writesRating = false
        let noRating = try XMPSidecar.read(XMPSidecar.fresh(mark: SidecarMark(decision: .rejected, rating: 2), mapping: mapping))
        #expect(noRating.rating == nil)
    }

    @Test func mergingIntoALightroomSidecarChangesOnlyRatingAndLabel() throws {
        let original = Data(SampleSidecars.lightroom.utf8)
        let before = try XMPSidecar.read(original)
        #expect(before.rating == 2 && before.label == "Yellow" && before.decision == nil)

        let merged = try XMPSidecar.merged(original, mark: SidecarMark(decision: .rejected, rating: 2))
        let after = try XMPSidecar.read(merged)
        #expect(after.rating == -1 && after.label == "Red" && after.decision == .rejected && after.cullaRating == 2)
        let text = string(merged)
        // Values replaced in place, and Culla's namespace and fields added after the last
        // attribute with the same indentation; everything else byte for byte.
        #expect(text.contains("   xmp:Rating=\"-1\"\n   xmp:Label=\"Red\"\n"))
        #expect(text.contains("crs:HasSettings=\"True\"\n   xmlns:culla=\"\(XMPSidecar.cullaNamespace)\"\n   culla:Decision=\"rejected\"\n   culla:Rating=\"2\">"))
        let restored = reverting(text, [
            ("xmp:Rating=\"2\"", "xmp:Rating=\"-1\""),
            ("xmp:Label=\"Yellow\"", "xmp:Label=\"Red\""),
            ("", "\n   xmlns:culla=\"\(XMPSidecar.cullaNamespace)\"\n   culla:Decision=\"rejected\"\n   culla:Rating=\"2\""),
        ])
        #expect(restored == SampleSidecars.lightroom)

        // Merging the same mark again changes nothing.
        #expect(try XMPSidecar.merged(merged, mark: SidecarMark(decision: .rejected, rating: 2)) == merged)
    }

    @Test func mergingIntoACaptureOneSidecarKeepsTheWrapperAndElementForm() throws {
        let original = Data(SampleSidecars.captureOne.utf8)
        #expect(try XMPSidecar.read(original).rating == 4)
        let merged = try XMPSidecar.merged(original, mark: SidecarMark(decision: .kept, rating: 5))
        let text = string(merged)
        #expect(text.contains("<xmp:Rating>5</xmp:Rating>"))
        #expect(text.contains("<xmp:Label>Green</xmp:Label>"))
        #expect(text.hasPrefix("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"))
        #expect(text.hasSuffix(String(repeating: " ", count: 400) + "\n<?xpacket end=\"w\"?>"))
        let fields = try XMPSidecar.read(merged)
        #expect(fields == XMPSidecarFields(rating: 5, label: "Green", decision: .kept, cullaRating: 5))
        let added = "\n            xmlns:culla=\"\(XMPSidecar.cullaNamespace)\"\n            culla:Decision=\"kept\"\n            culla:Rating=\"5\""
        let restored = reverting(text, [
            ("<xmp:Rating>4</xmp:Rating>", "<xmp:Rating>5</xmp:Rating>"),
            ("<xmp:Label>Purple</xmp:Label>", "<xmp:Label>Green</xmp:Label>"),
            ("", added),
        ])
        #expect(restored == SampleSidecars.captureOne)
    }

    @Test func severalDescriptionsUnknownNamespacesAndCommentsSurvive() throws {
        let original = Data(SampleSidecars.severalDescriptions.utf8)
        // `xap` is an old prefix for the xmp namespace; it is found by namespace, not by name.
        #expect(try XMPSidecar.read(original).rating == 5)
        let merged = try XMPSidecar.merged(original, mark: SidecarMark(decision: .unreviewed, rating: 3))
        let text = string(merged)
        #expect(text.contains("<xap:Rating>3</xap:Rating>"))
        #expect(!text.contains("xmp:Rating"))
        // Culla's fields go in as attributes, single-quoted like the file, on the first block
        // (none declares Culla's namespace), and no label is written for an unreviewed photo.
        let added = "\n  xmlns:culla='\(XMPSidecar.cullaNamespace)'\n  culla:Decision='unreviewed'\n  culla:Rating='3'"
        #expect(text.contains("xmlns:tiff='http://ns.adobe.com/tiff/1.0/'" + added + ">"))
        let restored = reverting(text, [("<xap:Rating>5</xap:Rating>", "<xap:Rating>3</xap:Rating>"), ("", added)])
        #expect(restored == SampleSidecars.severalDescriptions)
        #expect(try XMPSidecar.read(merged) == XMPSidecarFields(rating: 3, label: nil, decision: .unreviewed, cullaRating: 3))
    }

    @Test func aRatingInSeveralBlocksIsSetInEach() throws {
        let original = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="1"/>
            <rdf:Description rdf:about="" xmlns:a="http://ns.adobe.com/xap/1.0/"><a:Rating>1</a:Rating></rdf:Description>
            </rdf:RDF></x:xmpmeta>
            """
        let merged = string(try XMPSidecar.merged(Data(original.utf8), mark: SidecarMark(decision: .kept, rating: 4)))
        #expect(merged.contains("xmp:Rating=\"4\""))
        #expect(merged.contains("<a:Rating>4</a:Rating>"))
        // Missing fields go to the first block that already has the xmp namespace in scope, after
        // its last attribute, with a declaration for Culla's namespace.
        #expect(merged.contains("xmp:Rating=\"4\" xmlns:culla=\"\(XMPSidecar.cullaNamespace)\" xmp:Label=\"Green\" culla:Decision=\"kept\" culla:Rating=\"4\"/>"))
    }

    @Test func aByteOrderMarkIsKept() throws {
        let body = Data(XMPSidecar.fresh(mark: SidecarMark(decision: .kept, rating: 1)))
        let withMark = Data([0xEF, 0xBB, 0xBF]) + body
        #expect(try XMPSidecar.read(withMark).decision == .kept)
        let merged = try XMPSidecar.merged(withMark, mark: SidecarMark(decision: .rejected, rating: 1))
        #expect(merged.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(try XMPSidecar.read(merged).decision == .rejected)
        #expect(Data(merged.dropFirst(3)) == (try XMPSidecar.merged(body, mark: SidecarMark(decision: .rejected, rating: 1))))
    }

    @Test func specialCharactersInLabelsAreEscaped() throws {
        var mapping = SidecarMapping()
        mapping.keptLabel = "Keep & \"Show\" <now>"
        let data = XMPSidecar.fresh(mark: SidecarMark(decision: .kept, rating: 0), mapping: mapping)
        #expect(try XMPSidecar.read(data).label == "Keep & \"Show\" <now>")
        #expect(string(data).contains("xmp:Label=\"Keep &amp; &quot;Show&quot; &lt;now&gt;\""))
    }

    @Test func aKeptPhotoWithoutStarsLeavesAnotherProgramsRatingAlone() throws {
        let original = Data(SampleSidecars.lightroom.utf8)
        let merged = try XMPSidecar.merged(original, mark: SidecarMark(decision: .kept, rating: 0))
        #expect(try XMPSidecar.read(merged).rating == 2)
        // But a reject taken back clears the -1.
        let rejected = try XMPSidecar.merged(original, mark: SidecarMark(decision: .rejected, rating: 0))
        let keptAgain = try XMPSidecar.merged(rejected, mark: SidecarMark(decision: .kept, rating: 0))
        #expect(try XMPSidecar.read(keptAgain).rating == 0)
    }

    @Test(arguments: [
        "not xml at all",
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">",
        "<a><b></a></b>",
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>",
        "<!DOCTYPE x [<!ENTITY e \"boom\">]><x>&e;</x>",
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"><xmp:Rating><rdf:Alt/></xmp:Rating></rdf:Description></rdf:RDF></x:xmpmeta>",
    ])
    func unparseableSidecarsAreLeftAlone(text: String) throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("a.xmp", contents: Data(text.utf8))
        let stamp = FileOps.stamp(url.path)
        #expect(throws: XMPSidecarError.self) {
            try XMPSidecar.write(mark: SidecarMark(decision: .rejected, rating: 0), to: url)
        }
        #expect(try Data(contentsOf: url) == Data(text.utf8))
        #expect(FileOps.stamp(url.path) == stamp)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["a.xmp"])
    }

    @Test func utf16SidecarsAreLeftAlone() throws {
        let data = Data([0xFF, 0xFE]) + SampleSidecars.lightroom.data(using: .utf16LittleEndian)!
        #expect(throws: XMPSidecarError.notUTF8) { try XMPSidecar.read(data) }
    }

    @Test func writingReturnsWhatRestoresThePreviousStateByteForByte() throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("IMG_1.xmp", contents: Data(SampleSidecars.captureOne.utf8))
        try FileOps.setModificationTime(FileStamp(size: 0, seconds: 1_700_000_000, nanoseconds: 123_456_789), of: url.path)
        let before = FileOps.stamp(url.path)!

        let result = try XMPSidecar.write(mark: SidecarMark(decision: .rejected, rating: 1), to: url)
        #expect(result.changed)
        #expect(result.previous == .existed(Data(SampleSidecars.captureOne.utf8), before))
        #expect(try Data(contentsOf: url) == result.written)
        #expect(try XMPSidecar.read(contentsOf: url).decision == .rejected)

        #expect(try XMPSidecar.restore(result.previous, written: result.written, at: url))
        #expect(try Data(contentsOf: url) == Data(SampleSidecars.captureOne.utf8))
        #expect(FileOps.stamp(url.path) == before)
        // Restoring again finds it already restored.
        #expect(try XMPSidecar.restore(result.previous, written: result.written, at: url) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["IMG_1.xmp"])

        // A new sidecar restores to no file.
        let fresh = folder.url.appendingPathComponent("IMG_2.xmp")
        let written = try XMPSidecar.write(mark: SidecarMark(decision: .kept, rating: 3), to: fresh)
        #expect(written.previous == .absent)
        #expect(try XMPSidecar.restore(written.previous, written: written.written, at: fresh))
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func restoreLeavesASidecarChangedSinceAlone() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("IMG_1.xmp")
        let result = try XMPSidecar.write(mark: SidecarMark(decision: .kept, rating: 3), to: url)
        let edited = try XMPSidecar.merged(result.written, mark: SidecarMark(decision: .kept, rating: 5))
        try edited.write(to: url)
        #expect(throws: XMPSidecar.RestoreConflict.changedSince) {
            try XMPSidecar.restore(result.previous, written: result.written, at: url)
        }
        #expect(try Data(contentsOf: url) == edited)
    }

    @Test func commitRefusesWhenTheSidecarChangedAfterPreparing() throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("IMG_1.xmp", contents: Data(SampleSidecars.lightroom.utf8))
        let (previous, written) = try XMPSidecar.prepareWrite(mark: SidecarMark(decision: .kept, rating: 1), mapping: SidecarMapping(), at: url)
        try Data(SampleSidecars.captureOne.utf8).write(to: url)
        #expect(throws: XMPSidecarError.self) {
            try XMPSidecar.commitWrite(written, previous: previous, at: url, tempPath: FileOps.temporaryPath(beside: url.path))
        }
        #expect(try Data(contentsOf: url) == Data(SampleSidecars.captureOne.utf8))
        // A new sidecar never replaces a file that appeared meanwhile.
        let other = folder.url.appendingPathComponent("IMG_2.xmp")
        let (absent, fresh) = try XMPSidecar.prepareWrite(mark: SidecarMark(decision: .kept, rating: 1), mapping: SidecarMapping(), at: other)
        try Data("theirs".utf8).write(to: other)
        #expect(throws: (any Error).self) {
            try XMPSidecar.commitWrite(fresh, previous: absent, at: other, tempPath: FileOps.temporaryPath(beside: other.path))
        }
        #expect(try Data(contentsOf: other) == Data("theirs".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted() == ["IMG_1.xmp", "IMG_2.xmp"])
    }

    @Test func roundTripThroughAFile() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("IMG_9.xmp")
        for decision in SidecarDecision.allCases {
            for rating in 0...5 {
                let mark = SidecarMark(decision: decision, rating: rating)
                try XMPSidecar.write(mark: mark, to: url)
                #expect(try XMPSidecar.read(contentsOf: url).mark == mark)
            }
        }
    }

    @Test func sidecarsAreFoundBesideTheirPhotos() {
        let names = ["IMG_1.JPG", "IMG_1.CR3", "img_1.XMP", "IMG_1.CR3.xmp", "IMG_10.xmp", "IMG_1.xmp.bak"]
        #expect(SidecarFinder.sidecars(forFiles: ["IMG_1.JPG", "IMG_1.CR3"], in: names) == ["IMG_1.CR3.xmp", "img_1.XMP"])
        #expect(SidecarFinder.sidecars(forFiles: ["IMG_1.JPG", "IMG_1.CR3"], in: names, includeBaseSidecar: false) == ["IMG_1.CR3.xmp"])
    }
}
