import CullaCore
import Foundation
import Testing

/// The catalog of test data next to this file: made-up entries with Russian and Turkmen forms.
private let fixture = Localizer(bundle: .module, table: "LocalizationFixture")

@Suite("Localization")
struct LocalizationTests {
    @Test func testsRenderEnglishWhateverTheMacIsSetTo() {
        #expect(Localization.isRunningTests)
        #expect(Localization.language == .english)
        #expect(fixture("Open the folder") == "Open the folder")
        #expect(Localization.number(1_240) == "1,240")
    }

    @Test func englishPluralForms() {
        Localization.withLanguage(.english) {
            #expect(fixture("\(1) photos") == "1 photo")
            #expect(fixture("\(3) photos") == "3 photos")
            #expect(fixture("\(1_240) photos") == "1,240 photos")
            #expect(fixture("fixture.files", default: "\(1) files") == "1 file")
            #expect(fixture("fixture.files", default: "\(21) files") == "21 files")
        }
    }

    @Test func russianPluralFormsFollowTheLanguageNotTheMac() {
        Localization.withLanguage(.russian) {
            #expect(fixture("\(1) photos") == "1 фотография")
            #expect(fixture("\(3) photos") == "3 фотографии")
            #expect(fixture("\(5) photos") == "5 фотографий")
            #expect(fixture("\(21) photos") == "21 фотография")
            #expect(fixture("fixture.files", default: "\(1) files") == "1 файл")
            #expect(fixture("fixture.files", default: "\(4) files") == "4 файла")
            #expect(fixture("fixture.files", default: "\(11) files") == "11 файлов")
            #expect(fixture("Open the folder") == "Открыть папку")
        }
    }

    @Test func turkmenPluralForms() {
        Localization.withLanguage(.turkmen) {
            #expect(fixture("\(1) photos") == "1 surat")
            #expect(fixture("\(5) photos") == "5 surat")
            #expect(fixture("fixture.files", default: "\(2) files") == "2 faýl")
            #expect(fixture("Open the folder") == "Bukjany aç")
        }
    }

    @Test func untranslatedEntriesFallBackToEnglish() {
        for language in [AppLanguage.russian, .turkmen] {
            Localization.withLanguage(language) {
                #expect(fixture("Not translated yet") == "Not translated yet")
                // English forms with English plural rules: 21 is "one" in Russian, not in English.
                #expect(fixture("\(21) frames") == "21 frames")
                #expect(fixture("\(1) frames") == "1 frame")
                // The English value, never the key.
                #expect(fixture("fixture.untranslated", default: "English only") == "English only")
            }
        }
    }

    @Test func aKeyMissingFromTheCatalogIsLoudInTests() {
        #expect(fixture("Nothing in the catalog says this").contains("missing catalog entry"))
        #expect(fixture("fixture.nothing", default: "Nothing").contains("missing catalog entry"))
    }

    @Test func overridesStayInTheirTask() async {
        await Localization.withLanguage(.russian) {
            #expect(Localization.language == .russian)
            await Task.yield()
            #expect(fixture("\(2) photos") == "2 фотографии")
        }
        #expect(Localization.language == .english)
    }

    @Test func formattingFollowsTheLanguage() {
        Localization.withLanguage(.english) {
            #expect(Localization.list(["P", "X", "U"], .or) == "P, X or U")
            #expect(Localization.list(["P", "X"], .and) == "P and X")
            #expect(Localization.decimal(0.26, fractionDigits: 2) == "0.26")
            #expect(Localization.percent(0.3) == "30%")
        }
        Localization.withLanguage(.russian) {
            #expect(Localization.list(["P", "X", "U"], .or) == "P, X или U")
            #expect(Localization.decimal(0.26, fractionDigits: 2) == "0,26")
            let number = Localization.number(1_240)
            #expect(number != "1,240" && number.hasSuffix("240"))
            #expect(Localization.locale.language.languageCode?.identifier == "ru")
        }
        Localization.withLanguage(.turkmen) {
            #expect(Localization.locale.language.languageCode?.identifier == "tk")
            #expect(!Localization.bytes(8_200_000_000).isEmpty)
        }
    }

    @Test func languageIdentifiers() {
        #expect(AppLanguage(identifier: "ru-RU") == .russian)
        #expect(AppLanguage(identifier: "tk_TM") == .turkmen)
        #expect(AppLanguage(identifier: "en-GB") == .english)
        #expect(AppLanguage(identifier: "de") == nil)
    }
}
