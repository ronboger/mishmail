import XCTest

final class TextDirectionTests: XCTestCase {

    // MARK: - Base direction

    func testEnglishIsLTR() {
        XCTAssertEqual(TextDirection.base(of: "Hello Yaniv"), .ltr)
        XCTAssertEqual(TextDirection.htmlDir(of: "Hello Yaniv"), "ltr")
    }

    func testHebrewIsRTL() {
        let he = "שלום רב,"
        XCTAssertEqual(TextDirection.base(of: he), .rtl)
        XCTAssertEqual(TextDirection.htmlDir(of: he), "rtl")
        XCTAssertTrue(TextDirection.isRTL(he))
    }

    func testFirstStrongWins_HebrewBeforeLatin() {
        let mixed = "ניסיתי היום להגיש at forms.gov.il"
        XCTAssertEqual(TextDirection.base(of: mixed), .rtl)
    }

    func testFirstStrongWins_LatinBeforeHebrew() {
        let mixed = "Re: בקשה לתעודת לידה"
        XCTAssertEqual(TextDirection.base(of: mixed), .ltr)
    }

    func testDigitsAloneAreNeutral() {
        XCTAssertEqual(TextDirection.base(of: "2028606"), .neutral)
        XCTAssertEqual(TextDirection.htmlDir(of: "2028606"), "ltr")
    }

    func testEmptyIsNeutral() {
        XCTAssertEqual(TextDirection.base(of: ""), .neutral)
        XCTAssertEqual(TextDirection.base(of: "   \n"), .neutral)
    }

    func testArabicIsRTL() {
        XCTAssertEqual(TextDirection.base(of: "مرحبا"), .rtl)
    }

    // MARK: - LTR isolate ranges

    func testBareHTTPURLIsIsolated() {
        let s = "ניסיתי באתר http://forms.gov.il&source=gmail&ust=123 מספר"
        let ranges = TextDirection.ltrIsolateNSRanges(in: s)
        XCTAssertEqual(ranges.count, 1)
        let ns = s as NSString
        XCTAssertEqual(ns.substring(with: ranges[0]),
                       "http://forms.gov.il&source=gmail&ust=123")
    }

    func testHTTPSAndMailtoIsolated() {
        let s = "see https://example.com and mailto:a@b.co please"
        let ranges = TextDirection.ltrIsolateNSRanges(in: s)
        XCTAssertEqual(ranges.count, 2)
        let ns = s as NSString
        XCTAssertEqual(ns.substring(with: ranges[0]), "https://example.com")
        XCTAssertEqual(ns.substring(with: ranges[1]), "mailto:a@b.co")
    }

    func testTrailingPunctuationExcluded() {
        let s = "go https://example.com/x."
        let ranges = TextDirection.ltrIsolateNSRanges(in: s)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((s as NSString).substring(with: ranges[0]),
                       "https://example.com/x")
    }

    func testBareHostnameIsIsolated() {
        let s = "ניסיתי באתר forms.gov.il היום"
        let spans = TextDirection.ltrIsolateSpans(in: s)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .host)
        XCTAssertEqual((s as NSString).substring(with: spans[0].range), "forms.gov.il")
    }

    func testFileExtensionIsNotBareHost() {
        XCTAssertFalse(TextDirection.isPlausibleBareHost("README.md"))
        XCTAssertTrue(TextDirection.ltrIsolateSpans(in: "see README.md please").isEmpty)
    }

    func testEmailDoesNotYieldBareHost() {
        // `@` lookbehind: must not isolate/linkify `gmail.com` out of an address.
        let spans = TextDirection.ltrIsolateSpans(in: "כתבו ל ron@gmail.com בבקשה")
        XCTAssertTrue(spans.isEmpty, "\(spans)")
        let html = ComposeLinks.htmlFragment(from: "כתבו ל ron@gmail.com בבקשה")
        XCTAssertFalse(html.contains("https://gmail.com"), html)
        XCTAssertFalse(html.contains("<a "), html)
    }

    func testArbitraryWordDotWordNotLinkified() {
        // Isolation may still skip denylisted TLDs; linkify must not fire.
        XCTAssertFalse(TextDirection.isLinkableHost("setup.sh"))
        XCTAssertFalse(TextDirection.isLinkableHost("foo.bar"))
        let html = ComposeLinks.htmlFragment(from: "run setup.sh now")
        XCTAssertFalse(html.contains("<a "), html)
    }

    func testFormsGovIlIsLinkable() {
        XCTAssertTrue(TextDirection.isLinkableHost("forms.gov.il"))
        let html = ComposeLinks.htmlFragment(from: "see forms.gov.il now")
        XCTAssertTrue(html.contains(#"href="https://forms.gov.il""#), html)
    }

    func testPhoneDoesNotSpanNewline() {
        let s = "שנה 2026\n1234567 סוף"
        let phones = TextDirection.ltrIsolateSpans(in: s).filter { $0.kind == .phone }
        // Second line alone is 7 digits — isolated; must not merge across \n.
        XCTAssertEqual(phones.count, 1)
        XCTAssertEqual((s as NSString).substring(with: phones[0].range), "1234567")
    }

    func testPhoneIsIsolated() {
        let s = "התקשרו +1-555-123-4567 בבקשה"
        let spans = TextDirection.ltrIsolateSpans(in: s)
        XCTAssertEqual(spans.count, 1, "\(spans)")
        XCTAssertEqual(spans[0].kind, .phone)
        XCTAssertEqual((s as NSString).substring(with: spans[0].range), "+1-555-123-4567")
    }

    func testLongIDIsIsolated() {
        let s = "מספר זהות 205892862 בבקשה"
        let spans = TextDirection.ltrIsolateSpans(in: s)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .phone)
        XCTAssertEqual((s as NSString).substring(with: spans[0].range), "205892862")
    }

    func testShortDigitsNotIsolatedAsPhone() {
        // Fewer than 7 digits — leave as weak numbers.
        let spans = TextDirection.ltrIsolateSpans(in: "קוד 1234 בלבד")
        XCTAssertTrue(spans.isEmpty, "\(spans)")
    }

    func testPureHebrewHasNoIsolates() {
        XCTAssertTrue(TextDirection.ltrIsolateNSRanges(in: "שלום בלבד").isEmpty)
    }

    // MARK: - Authored HTML dir wrapper contract

    func testAuthoredHeadHTML_HebrewGetsDirRTL() {
        let html = ComposeQuote.authoredHeadHTML("שלום רב,\n\nאנא עזרו.")
        XCTAssertTrue(html.contains(#"<div dir="rtl">"#), html)
        XCTAssertTrue(html.contains("שלום רב"), html)
        // Two blank-line paragraphs → two RTL wrappers.
        XCTAssertEqual(html.components(separatedBy: #"dir="rtl""#).count - 1, 2, html)
    }

    func testAuthoredHeadHTML_EnglishGetsDirLTR() {
        let html = ComposeQuote.authoredHeadHTML("Hi Yaniv, let's close.")
        XCTAssertTrue(html.hasPrefix(#"<div dir="ltr">"#), html)
        XCTAssertTrue(html.contains("Hi Yaniv"), html)
    }

    func testAuthoredHeadHTML_MixedParagraphsGetPerBlockDir() {
        // English greeting + Hebrew body must not force the whole message LTR.
        let html = ComposeQuote.authoredHeadHTML("Hi Yaniv,\n\nשלום רב, אנא עזרו.")
        XCTAssertTrue(html.contains(#"<div dir="ltr">Hi Yaniv,"#), html)
        XCTAssertTrue(html.contains(#"<div dir="rtl">שלום רב"#), html)
        // Blank-line split must not collapse paragraph gaps for recipients.
        XCTAssertTrue(html.contains(#"</div><div><br></div><div dir="rtl">"#), html)
    }

    func testAuthoredHeadHTML_MultiBlankLinesPreserved() {
        let html = ComposeQuote.authoredHeadHTML("Hi\n\n\nשלום")
        // Two blank lines → two spacers between paragraphs.
        let spacers = html.components(separatedBy: "<div><br></div>").count - 1
        XCTAssertEqual(spacers, 2, html)
    }

    func testAuthoredHeadHTML_WhitespaceOnlyLineIsBlank() {
        let html = ComposeQuote.authoredHeadHTML("Hi\n  \nשלום")
        XCTAssertTrue(html.contains(#"<div dir="ltr">Hi</div>"#), html)
        XCTAssertTrue(html.contains(#"<div dir="rtl">שלום</div>"#), html)
        XCTAssertTrue(html.contains("<div><br></div>"), html)
    }

    func testAuthoredHeadHTML_HebrewMarkdownGetsDirRTL() {
        let html = ComposeQuote.authoredHeadHTML("שלום **עולם**")
        // Markdown emits per-block dir (no outer wrapper).
        XCTAssertTrue(html.contains(#"<p dir="rtl">"#), html)
        XCTAssertTrue(html.contains("<strong>עולם</strong>"), html)
    }

    func testAuthoredHeadHTML_MarkdownMixedBlocksGetOwnDir() {
        let html = ComposeQuote.authoredHeadHTML("Hello **world**\n\nשלום **עולם**")
        XCTAssertTrue(html.contains(#"<p dir="ltr">"#), html)
        XCTAssertTrue(html.contains(#"<p dir="rtl">"#), html)
    }

    func testAuthoredHeadHTML_Empty() {
        XCTAssertEqual(ComposeQuote.authoredHeadHTML(""), "")
    }

    func testParagraphsSplitOnBlankLines() {
        XCTAssertEqual(TextDirection.paragraphs(in: "a\nb\n\nc"), ["a\nb", "c"])
        XCTAssertEqual(TextDirection.paragraphs(in: "only"), ["only"])
        XCTAssertEqual(TextDirection.paragraphs(in: ""), [])
    }

    func testBlocksPreserveBlankRuns() {
        let blocks = TextDirection.blocks(in: "a\n\n\nb")
        XCTAssertEqual(blocks, [
            .paragraph("a"),
            .blanks(2),
            .paragraph("b"),
        ])
    }

    func testHtmlFragment_AnchorsHaveDirLTR() {
        let html = ComposeLinks.htmlFragment(
            from: "ניסיתי http://forms.gov.il/x מספר")
        XCTAssertTrue(
            html.contains(#"<a href="http://forms.gov.il/x" dir="ltr">http://forms.gov.il/x</a>"#),
            html)
    }

    func testHtmlFragment_BareHostAutolinked() {
        let html = ComposeLinks.htmlFragment(from: "see forms.gov.il now")
        XCTAssertTrue(html.contains(#"href="https://forms.gov.il""#), html)
        XCTAssertTrue(html.contains(#"dir="ltr""#), html)
    }

    func testHtmlFragment_PhoneWrappedInSpan() {
        let html = ComposeLinks.htmlFragment(from: "call +1-555-123-4567 please")
        XCTAssertTrue(html.contains(#"<span dir="ltr">+1-555-123-4567</span>"#), html)
    }

    func testHtmlFragment_MarkdownLinkHasDirLTR() {
        let html = ComposeLinks.htmlFragment(from: "see [docs](https://example.com/a)")
        XCTAssertTrue(html.contains(#"dir="ltr""#), html)
        XCTAssertTrue(html.contains("href=\"https://example.com/a\""), html)
    }
}
