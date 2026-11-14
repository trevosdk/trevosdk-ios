import Foundation
import XCTest

@testable import TrevoSDK

private let headline: TrevoValue = [
    "locales": ["en": "Start free", "de": "Kostenlos starten", "pt": "Comece", "pt-BR": "Comece grátis"]
]

final class TranslatedTextTests: XCTestCase {
    func testPrefersTheFullTagOverItsLanguage() {
        XCTAssertEqual(TranslatedText.text(headline, locale: "pt-BR"), "Comece grátis")
        XCTAssertEqual(TranslatedText.text(headline, locale: "PT-br"), "Comece grátis")
    }

    func testFallsBackFromARegionToItsLanguage() {
        let text: TrevoValue = ["locales": ["pt": "Comece"]]
        XCTAssertEqual(TranslatedText.text(text, locale: "pt-BR"), "Comece")
    }

    func testKeepsTheScriptWhenDroppingTheRegion() {
        let text: TrevoValue = ["locales": ["zh": "开始", "zh-Hans": "免费开始"]]
        XCTAssertEqual(TranslatedText.text(text, locale: "zh-Hans-CN"), "免费开始")
    }

    // A Portuguese reader in Brazil gets the app's own text, not the text written for Portugal.
    func testNeverServesAnotherRegionsText() {
        let text: TrevoValue = ["locales": ["pt-PT": "Comece gratuitamente"]]
        XCTAssertNil(TranslatedText.text(text, locale: "pt-BR"))
    }

    func testReadsAPosixLocaleName() {
        XCTAssertEqual(TranslatedText.text(headline, locale: "de_DE.UTF-8"), "Kostenlos starten")
        XCTAssertEqual(TranslatedText.text(headline, locale: "pt_BR@euro"), "Comece grátis")
    }

    func testHasNoTextForAMissingLanguage() {
        XCTAssertNil(TranslatedText.text(headline, locale: "fr-FR"))
    }

    func testSkipsEntriesThatAreNotText() {
        let text: TrevoValue = ["locales": ["pt-BR": 5, "pt-PT": "", "pt": "Comece"]]
        XCTAssertEqual(TranslatedText.text(text, locale: "pt-BR"), "Comece")
        XCTAssertEqual(TranslatedText.text(text, locale: "pt-PT"), "Comece")
    }

    func testNeverStopsOnASingletonSubtag() {
        let text: TrevoValue = ["locales": ["en-x": "Private", "en": "Start free"]]
        XCTAssertEqual(TranslatedText.text(text, locale: "en-x-twain"), "Start free")
    }

    func testIgnoresAnObjectWithoutLocales() {
        XCTAssertNil(TranslatedText.text(["de": "Kostenlos starten"], locale: "de"))
        XCTAssertNil(TranslatedText.text(["locales": ["de", "Kostenlos starten"]], locale: "de"))
    }
}

final class LocaleTests: XCTestCase {
    private static let config: Data = {
        let params: [String: TrevoValue] = ["paywall.headline": headline, "paywall.cta": "Go"]
        return configBody([
            experimentJSON(
                "paywall", [("control", 50), ("treatment", 50)],
                params: ["control": params, "treatment": params])
        ])
    }()

    private func client(
        locale: String? = nil, transport: FakeTransport = FakeTransport(config: LocaleTests.config)
    ) async -> TrevoClient {
        let client = makeClient(transport: transport, locale: locale)
        await client.ready()
        return client
    }

    func testReadsTextPerLanguageInTheLocaleFromOptions() async {
        let client = await client(locale: "de-AT")
        XCTAssertEqual(client.getParameter("paywall.headline", default: "Subscribe"), "Kostenlos starten")
        XCTAssertEqual(client.getParameter("paywall.cta", default: "Buy"), "Go")
    }

    func testSetLocaleOutranksOptionsAndNilGoesBack() async {
        let client = await client(locale: "de")
        client.setLocale("pt-BR")
        XCTAssertEqual(client.getParameter("paywall.headline", default: "Subscribe"), "Comece grátis")
        client.setLocale(nil)
        XCTAssertEqual(client.getParameter("paywall.headline", default: "Subscribe"), "Kostenlos starten")
        client.setLocale("en")
        client.setLocale("  ")
        XCTAssertEqual(client.getParameter("paywall.headline", default: "Subscribe"), "Kostenlos starten")
    }

    func testServesTheDefaultForAMissingLanguageAndStillRecordsTheExposure() async {
        let transport = FakeTransport(config: Self.config)
        let client = await client(locale: "fr", transport: transport)
        XCTAssertEqual(client.getParameter("paywall.headline", default: "Subscribe"), "Subscribe")
        await client.flush()
        XCTAssertEqual(transport.sentEvents.map { $0["event"] }, ["$experiment_exposure"])
    }

    func testServesTheDefaultWhenTextPerLanguageIsReadAsAnotherType() async {
        let client = await client(locale: "de")
        XCTAssertFalse(client.getParameter("paywall.headline", default: false))
        XCTAssertEqual(client.getParameter("paywall.headline", default: 7), 7)
        XCTAssertEqual(client.getParameter("paywall.headline", default: 0.5), 0.5)
    }

    func testNotifiesListenersOnlyWhenTheLocaleChanges() async {
        let client = await client()
        let count = Counter()
        let subscription = client.onChange { count.increment() }
        client.setLocale("de")
        await waitUntil("the locale notification") { count.value == 1 }

        client.setLocale(" de ")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(count.value, 1)
        subscription.cancel()
    }
}
