import XCTest

final class GreetingAutocompleteTests: XCTestCase {

    // MARK: - firstName

    func testFirstNameSplitsOnWhitespace() {
        XCTAssertEqual(GreetingAutocomplete.firstName(of: "Alice Smith"), "Alice")
        XCTAssertEqual(GreetingAutocomplete.firstName(of: "  Bob  "), "Bob")
        XCTAssertEqual(GreetingAutocomplete.firstName(of: ""), "")
        XCTAssertEqual(GreetingAutocomplete.firstName(of: "   "), "")
        // Tabs / non-breaking-ish whitespace, not only literal space.
        XCTAssertEqual(GreetingAutocomplete.firstName(of: "Ann\tLee"), "Ann")
    }

    // MARK: - usable names / recipient resolution

    func testUsablePersonNameRejectsEmailShaped() {
        XCTAssertTrue(GreetingAutocomplete.isUsablePersonName("Alice"))
        XCTAssertTrue(GreetingAutocomplete.isUsablePersonName("John Doe"))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName(""))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("   "))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("John@ormoni.bio"))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("john@x.com"))
    }

    func testUsablePersonNameRejectsRoleMailboxes() {
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("Backoffice"))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("backoffice"))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("Customer Support"))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("Support Team"))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("no-reply"))
        XCTAssertFalse(GreetingAutocomplete.isUsablePersonName("Notifications"))
        // Real people still pass.
        XCTAssertTrue(GreetingAutocomplete.isUsablePersonName("Jordan"))
        XCTAssertTrue(GreetingAutocomplete.isUsablePersonName("Supportive Sue"))
    }

    func testRecipientFirstNamePrefersContactOverLocalPart() {
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "john@ormoni.bio", contactName: "John Casey"),
            "John")
    }

    func testRecipientFirstNamePrefersLastSenderHeader() {
        // Reply To is bare email; From header on the message being replied to
        // carries the real name — prefer that over a contact local-part guess.
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "john@ormoni.bio",
                contactName: nil,
                headerName: "John Casey"),
            "John")
        // Header wins over a weaker contact when both usable.
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "j@x.com",
                contactName: "J",
                headerName: "Jordan Lee"),
            "Jordan")
    }

    func testRecipientFirstNameRejectsEmailShapedContact() {
        // The bug in the screenshot: contact.name was the bare address
        // (MessageParser.displayName on a From without angle brackets), and
        // greeting used it wholesale → "Hi John@ormoni.bio,".
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "John@ormoni.bio", contactName: "John@ormoni.bio"),
            "John")
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "john@ormoni.bio", contactName: "john@ormoni.bio"),
            "John")
    }

    func testRecipientFirstNameSuppressesBackoffice() {
        // Shared mailbox From: "Backoffice <ops@company.com>" — no ghost.
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "ops@company.com",
                contactName: "Backoffice",
                headerName: "Backoffice"),
            "")
        // Local-part guess "Backoffice" from backoffice@… is also suppressed.
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "backoffice@company.com", contactName: nil),
            "")
    }

    func testRecipientFirstNameFromAngleBracketToken() {
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "Alice Smith <alice@x.com>", contactName: nil),
            "Alice")
    }

    func testRecipientFirstNameEmptyWhenNothingUsable() {
        // Local part is empty-ish after parse? Bare "@host" is junk.
        XCTAssertEqual(
            GreetingAutocomplete.recipientFirstName(
                token: "@x.com", contactName: nil),
            "")
    }

    func testPersonFromBareLocalPartTitleCases() {
        let p = GreetingAutocomplete.person(from: "john.doe@x.com")
        XCTAssertEqual(p.name, "John Doe")
        XCTAssertEqual(p.email, "john.doe@x.com")
    }

    // MARK: - tone

    func testToneCasualFromHeyOpener() {
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Hey Ron,\n\nQuick question."),
            .casual)
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "yo — are you free?"),
            .casual)
    }

    func testToneFormalFromDearOrHello() {
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Dear Ron,\n\nPlease find attached."),
            .formal)
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Hello Ron,\n\nI hope this finds you well."),
            .formal)
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Hello"),
            .formal)
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Hello!"),
            .formal)
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Thanks.\n\nBest regards,\nAlice"),
            .formal)
    }

    func testToneDoesNotTreatPartyAsCasualTy() {
        // Dropped the "ty!" marker so "party!" / "warranty!" stay neutral.
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "The warranty! expires soon."),
            .neutral)
    }

    func testToneNeutralDefaultAndHi() {
        XCTAssertEqual(GreetingAutocomplete.tone(ofPreviousBody: ""), .neutral)
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Hi Ron,\n\nFollowing up on the deck."),
            .neutral)
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Can we move the meeting to 3pm?"),
            .neutral)
    }

    func testToneCasualFromBodySignals() {
        XCTAssertEqual(
            GreetingAutocomplete.tone(ofPreviousBody: "Hi!\n\nlol that was funny haha"),
            .casual)
    }

    // MARK: - empty body → tone-aware default

    func testEmptyBodySuggestsHiName() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 0, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        XCTAssertEqual(s?.ghost, "Hi Alice, ")
    }

    func testEmptyBodyCasualSuggestsHey() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 0, firstName: "Alice", tone: .casual)
        XCTAssertEqual(s?.full, "Hey Alice, ")
        XCTAssertEqual(s?.ghost, "Hey Alice, ")
    }

    func testEmptyBodyFormalSuggestsHello() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 0, firstName: "Alice", tone: .formal)
        XCTAssertEqual(s?.full, "Hello Alice, ")
    }

    func testEmptyFirstNameYieldsNil() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 0, firstName: ""))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "H", caretUTF16: 1, firstName: "  "))
    }

    func testEmailShapedFirstNameYieldsNil() {
        // Defense in depth: even if a caller passes a bad first name, no ghost.
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 0, firstName: "John@ormoni.bio"))
    }

    // MARK: - prefix matching

    func testPartialHiOpener() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "H", caretUTF16: 1, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        XCTAssertEqual(s?.ghost, "i Alice, ")
    }

    func testAmbiguousHPrefersHeyWhenCasual() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "H", caretUTF16: 1, firstName: "Ron", tone: .casual)
        XCTAssertEqual(s?.full, "Hey Ron, ")
    }

    func testHiWithSpaceSuggestsName() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "Hi ", caretUTF16: 3, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        XCTAssertEqual(s?.ghost, "Alice, ")
    }

    func testPartialName() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "Hi Al", caretUTF16: 5, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        XCTAssertEqual(s?.ghost, "ice, ")
    }

    func testHeyOpener() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "Hey", caretUTF16: 3, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hey Alice, ")
        XCTAssertEqual(s?.ghost, " Alice, ")
    }

    func testHelloOpener() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "Hel", caretUTF16: 3, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hello Alice, ")
        XCTAssertEqual(s?.ghost, "lo Alice, ")
    }

    func testCaseInsensitivePrefix() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "hi", caretUTF16: 2, firstName: "Alice")
        XCTAssertEqual(s?.full, "Hi Alice, ")
        // Ghost is the template remainder from UTF-16 length 2.
        XCTAssertEqual(s?.ghost, " Alice, ")
    }

    func testCompleteGreetingHidesGhost() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi Alice, ", caretUTF16: 10, firstName: "Alice"))
        // Case-insensitive complete also hides.
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "hi alice, ", caretUTF16: 10, firstName: "Alice"))
    }

    // MARK: - gating

    func testCaretNotAtEndHidesGhost() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi", caretUTF16: 0, firstName: "Alice"))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi", caretUTF16: 1, firstName: "Alice"))
    }

    func testCaretPastHeadDoesNotClampIntoGreeting() {
        // Empty authored head + caret inside the quoted tail (UTF-16 offset
        // past head length). Must not clamp to end-of-head and offer Hi Name.
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: 5, firstName: "Alice"))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi", caretUTF16: 40, firstName: "Alice"))
        // Negative caret is also not "at end".
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "", caretUTF16: -1, firstName: "Alice"))
    }

    func testMultilineHeadHidesGhost() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi\n", caretUTF16: 3, firstName: "Alice"))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi Alice, \nMore", caretUTF16: 16, firstName: "Alice"))
    }

    func testNonGreetingPrefixHidesGhost() {
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Thanks", caretUTF16: 6, firstName: "Alice"))
        XCTAssertNil(GreetingAutocomplete.suggestion(
            authoredBody: "Hi Bob", caretUTF16: 6, firstName: "Alice"))
    }

    func testAmbiguousHPrefersHi() {
        // "H" is a prefix of Hi, Hey, and Hello — Hi wins (opener order).
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "H", caretUTF16: 1, firstName: "Ron")
        XCTAssertEqual(s?.full, "Hi Ron, ")
    }

    func testHePrefersHeyOverHello() {
        let s = GreetingAutocomplete.suggestion(
            authoredBody: "He", caretUTF16: 2, firstName: "Ron")
        XCTAssertEqual(s?.full, "Hey Ron, ")
    }

    // MARK: - apply

    func testApplyingReplacesHeadKeepsTail() {
        let s = GreetingAutocomplete.Suggestion(full: "Hi Alice, ", ghost: "i Alice, ")
        let result = GreetingAutocomplete.applying(
            s, toBody: "H\n\nOn Mon wrote:\nhey", authoredHeadEndUTF16: 1)
        XCTAssertEqual(result.body, "Hi Alice, \n\nOn Mon wrote:\nhey")
        XCTAssertEqual(result.caretUTF16, ("Hi Alice, " as NSString).length)
    }

    func testApplyingOnEmptyBody() {
        let s = GreetingAutocomplete.Suggestion(full: "Hi Alice, ", ghost: "Hi Alice, ")
        let result = GreetingAutocomplete.applying(
            s, toBody: "", authoredHeadEndUTF16: 0)
        XCTAssertEqual(result.body, "Hi Alice, ")
        XCTAssertEqual(result.caretUTF16, 10)
    }
}
