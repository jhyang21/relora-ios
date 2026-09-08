import Foundation
import Testing
@testable import ReloraFeatures

/// Pinned against `apps/mobile/src/utils/phoneNumber.ts`, which this is a 1:1
/// port of. Every case below is a behaviour of that file, not a preference of
/// this one — the two clients have to agree while both ship.
@Suite("PhoneNumberFormat.display")
struct PhoneNumberFormatDisplayTests {
    @Test("Ten NANP digits get grouped")
    func tenDigits() {
        #expect(PhoneNumberFormat.display("5552034567") == "(555) 203-4567")
    }

    @Test("Eleven digits starting with 1 keep the country code")
    func elevenDigits() {
        #expect(PhoneNumberFormat.display("15552034567") == "+1 (555) 203-4567")
        #expect(PhoneNumberFormat.display("+1 555 203 4567") == "+1 (555) 203-4567")
    }

    @Test("An already-grouped number survives a round trip")
    func alreadyFormatted() {
        #expect(PhoneNumberFormat.display("(555) 203-4567") == "(555) 203-4567")
    }

    /// A "+" that is not "+1" names a country this formatter knows nothing
    /// about, so it is handed back untouched.
    @Test("A non-NANP international number is left exactly as it is")
    func internationalUntouched() {
        #expect(PhoneNumberFormat.display("+44 20 7946 0958") == "+44 20 7946 0958")
    }

    /// Area code and exchange both start 2–9 in every NANP number. An
    /// Australian "02 9374 4000" must not come back as "(029) 374-4000".
    @Test("Ten digits that fail the NANP shape are left alone")
    func nonNANPTenDigits() {
        #expect(PhoneNumberFormat.display("1234567890") == "1234567890")
        #expect(PhoneNumberFormat.display("5551034567") == "5551034567")
    }

    @Test("Anything with no usable digits comes back trimmed and unchanged")
    func lettersAndBlanks() {
        #expect(PhoneNumberFormat.display("abc") == "abc")
        #expect(PhoneNumberFormat.display("") == "")
        #expect(PhoneNumberFormat.display("   ") == "")
        #expect(PhoneNumberFormat.display("  5552034567  ") == "(555) 203-4567")
    }
}

@Suite("PhoneNumberFormat.dialable")
struct PhoneNumberFormatDialableTests {
    @Test("Grouping characters are stripped")
    func stripsGrouping() {
        #expect(PhoneNumberFormat.dialable("(555) 203-4567") == "5552034567")
    }

    @Test("A leading plus is kept, everything else is digits")
    func keepsLeadingPlus() {
        #expect(PhoneNumberFormat.dialable("+44 20 7946 0958") == "+442079460958")
        #expect(PhoneNumberFormat.dialable("+1 (555) 203-4567") == "+15552034567")
    }

    @Test("Nothing to dial gives nil")
    func noDigitsGivesNil() {
        #expect(PhoneNumberFormat.dialable("") == nil)
        #expect(PhoneNumberFormat.dialable("   ") == nil)
        #expect(PhoneNumberFormat.dialable("call me") == nil)
    }
}
