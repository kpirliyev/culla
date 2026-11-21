import CullaAnalysis
import Foundation
import Testing

@Suite("DuplicateRanking")
struct DuplicateRankingTests {
    private func copy(_ name: String, pixels: Int? = 24_000_000, raw: Bool = false, path: String? = nil) -> DuplicateCopy {
        DuplicateCopy(pixelCount: pixels, hasRAW: raw, fileName: name, tieBreaker: path ?? name)
    }

    @Test func highestResolutionComesFirst() {
        let copies = [
            copy("IMG_0001.jpg", pixels: 6_000_000, raw: true),
            copy("IMG_0001 copy.jpg", pixels: 24_000_000),
        ]
        let pick = DuplicateRanking.pick(copies)
        #expect(pick?.index == 1)
        #expect(pick?.reason == .highestResolution)
        #expect(pick?.reasons == [.highestResolution])
        #expect(pick?.reason.description == "highest resolution")
    }

    @Test func anUnknownSizeLosesToAKnownOne() {
        let pick = DuplicateRanking.pick([copy("a.jpg", pixels: nil), copy("b.jpg", pixels: 100)])
        #expect(pick?.index == 1 && pick?.reason == .highestResolution)
    }

    @Test func atTheSameResolutionRAWBeatsJPEG() {
        let copies = [copy("IMG_0001.jpg"), copy("IMG_0001 copy.dng", raw: true)]
        let pick = DuplicateRanking.pick(copies)
        #expect(pick?.index == 1)
        #expect(pick?.reason == .rawFile)
        #expect(pick?.reason.description == "RAW file")
    }

    @Test func thenTheOriginalNameBeatsACopyName() {
        let copies = [copy("IMG_0001 copy.jpg"), copy("IMG_0001.jpg"), copy("IMG_0001 (1).jpg")]
        let pick = DuplicateRanking.pick(copies)
        #expect(pick?.index == 1)
        #expect(pick?.reason == .originalName)
        #expect(pick?.reason.description == "original name")
        #expect(DuplicateRanking.ranking(copies) == [1, 2, 0])
    }

    @Test func thenTheShorterName() {
        let copies = [copy("Holiday-export-final.jpg"), copy("Holiday.jpg")]
        let pick = DuplicateRanking.pick(copies)
        #expect(pick?.index == 1 && pick?.reason == .shorterName)
    }

    @Test func thenTheFirstByNameThenByPath() {
        let byName = DuplicateRanking.pick([copy("b_01.jpg"), copy("a_01.jpg")])
        #expect(byName?.index == 1 && byName?.reason == .firstByName)
        // Numbers compare as numbers, case is ignored.
        #expect(DuplicateRanking.pick([copy("img10.jpg"), copy("IMG9.jpg")])?.index == 1)
        // The same name in two folders: the path decides.
        let byPath = DuplicateRanking.pick([copy("IMG_1.jpg", path: "b/IMG_1.jpg"), copy("IMG_1.jpg", path: "a/IMG_1.jpg")])
        #expect(byPath?.index == 1 && byPath?.reasons == [.firstByName])
    }

    @Test func reasonsListEveryRuleThatNarrowed() {
        let copies = [
            copy("IMG_0001.jpg", pixels: 1_000_000),
            copy("IMG_0001 copy.jpg", raw: true),
            copy("IMG_0001.jpg"),
            copy("IMG_0001 copy.jpg"),
        ]
        let pick = DuplicateRanking.pick(copies)
        #expect(pick?.index == 1)
        #expect(pick?.reasons == [.highestResolution, .rawFile])
        #expect(pick?.reason == .rawFile)
        #expect(DuplicateRanking.pick([]) == nil)
    }

    @Test(arguments: [
        "IMG_0001 copy.jpg", "IMG_0001 Copy.JPG", "IMG_0001 copy 2.jpg", "IMG_0001 copy 12.jpg",
        "IMG_0001-copy.jpg", "IMG_0001_copy.jpg", "IMG_0001 - Copy.jpg", "IMG_0001 - Copy (2).jpg",
        "IMG_0001 (1).jpg", "IMG_0001(2).jpg", "Copy of IMG_0001.jpg", "Copy (2) of IMG_0001.jpg",
        "IMG_0001 copy (1).jpg",
    ])
    func copyNamesAreRecognised(_ name: String) {
        #expect(DuplicateRanking.isCopyName(name, among: [name]))
    }

    @Test(arguments: ["IMG_0001-1.jpg", "IMG_0001_2.jpg", "IMG_0001 2.jpg", "img_0001-12.JPG"])
    func numberedNamesAreCopiesWhenTheOriginalIsThere(_ name: String) {
        #expect(DuplicateRanking.isCopyName(name, among: [name, "IMG_0001.jpg"]))
        #expect(DuplicateRanking.isCopyName(name, among: [name, "IMG_0001.CR3"]))
        #expect(!DuplicateRanking.isCopyName(name, among: [name]))
        #expect(!DuplicateRanking.isCopyName(name, among: [name, "IMG_0002.jpg"]))
    }

    @Test(arguments: ["IMG_0001.jpg", "DSC_12.jpg", "copy.jpg", "photocopy.jpg", "IMG_0012.jpg", "Copy.jpg", "(1).jpg", "Copy of.jpg"])
    func ordinaryNamesAreNotCopies(_ name: String) {
        #expect(!DuplicateRanking.isCopyName(name, among: [name, "IMG.jpg"]))
    }

    @Test func aCameraNumberIsNotACopyNumber() {
        // "IMG_0012" ends in a separator and digits, but four of them: a camera's counter.
        #expect(!DuplicateRanking.isCopyName("IMG_0012.jpg", among: ["IMG_0012.jpg", "IMG.jpg"]))
        // Two digits after a separator are a copy number only when the original is there.
        #expect(DuplicateRanking.isCopyName("DSC_12.jpg", among: ["DSC_12.jpg", "DSC.jpg"]))
    }

    @Test func theOriginalStemDropsCopyMarks() {
        #expect(DuplicateRanking.originalStem(of: "IMG_0001 copy 2 (1).JPG") == "img_0001")
        #expect(DuplicateRanking.originalStem(of: "Copy of IMG_0001.jpg") == "img_0001")
        #expect(DuplicateRanking.originalStem(of: "IMG_0001-1.jpg") == "img_0001-1")
    }
}
