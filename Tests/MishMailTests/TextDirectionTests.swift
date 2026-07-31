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

    // MARK: - LTR isolate ranges (URLs)

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

    func testNoURLMeansNoRanges() {
        XCTAssertTrue(TextDirection.ltrIsolateNSRanges(in: "שלום בלבד").isEmpty)
        XCTAssertTrue(TextDirection.ltrIsolateNSRanges(in: "no scheme example.com").isEmpty)
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

    func testAuthoredHeadHTML_HebrewMarkdownGetsDirRTL() {
        let html = ComposeQuote.authoredHeadHTML("שלום **עולם**")
        XCTAssertTrue(html.hasPrefix(#"<div dir="rtl">"#), html)
        XCTAssertTrue(html.contains("<strong>עולם</strong>"), html)
    }

    func testAuthoredHeadHTML_Empty() {
        XCTAssertEqual(ComposeQuote.authoredHeadHTML(""), "")
    }

    func testParagraphsSplitOnBlankLines() {
        XCTAssertEqual(TextDirection.paragraphs(in: "a\nb\n\nc"), ["a\nb", "c"])
        XCTAssertEqual(TextDirection.paragraphs(in: "only"), ["only"])
        XCTAssertEqual(TextDirection.paragraphs(in: ""), [])
    }

    func testHtmlFragment_AnchorsHaveDirLTR() {
        let html = ComposeLinks.htmlFragment(
            from: "ניסיתי http://forms.gov.il/x מספר")
        XCTAssertTrue(
            html.contains(#"<a href="http://forms.gov.il/x" dir="ltr">http://forms.gov.il/x</a>"#),
            html)
    }

    func testHtmlFragment_MarkdownLinkHasDirLTR() {
        let html = ComposeLinks.htmlFragment(from: "see [docs](https://example.com/a)")
        XCTAssertTrue(html.contains(#"dir="ltr""#), html)
        XCTAssertTrue(html.contains("href=\"https://example.com/a\""), html)
    }
}
