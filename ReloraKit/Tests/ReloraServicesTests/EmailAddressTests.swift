import Foundation
import Testing
@testable import ReloraServices

@Suite("EmailAddress.normalized")
struct EmailAddressNormalizedTests {
    @Test("Surrounding whitespace is removed")
    func trimsWhitespace() {
        #expect(EmailAddress.normalized("  ada@example.com ") == "ada@example.com")
        #expect(EmailAddress.normalized("\nada@example.com\t") == "ada@example.com")
    }

    /// The rule the redesign brief states outright: a legitimate address is
    /// never quietly rewritten. Case matters in the local part, plus-tags are
    /// how people file their mail, and an address the app changed is an
    /// account the user cannot sign back in to.
    @Test("Case, dots and plus tags survive untouched")
    func leavesTheAddressAlone() {
        #expect(EmailAddress.normalized("Ada.Lovelace+relora@Example.COM") == "Ada.Lovelace+relora@Example.COM")
    }
}

@Suite("EmailAddress.isValid")
struct EmailAddressValidityTests {
    @Test("Ordinary addresses pass", arguments: [
        "ada@example.com",
        "ada.lovelace@example.co.uk",
        "ada+relora@example.com",
        "a@b.io",
        "  ada@example.com  "
    ])
    func accepts(address: String) {
        #expect(EmailAddress.isValid(address))
    }

    @Test("What a person can see is wrong fails", arguments: [
        "",
        "   ",
        "ada",
        "ada@",
        "@example.com",
        "ada@example",
        "ada@example.",
        "ada@.com",
        "ada@example..com",
        "ada@@example.com",
        "ada lovelace@example.com",
        "ada@exa mple.com",
        "ada@example.c"
    ])
    func rejects(address: String) {
        #expect(!EmailAddress.isValid(address))
    }

    @Test("Length ceilings from RFC 5321 hold")
    func rejectsOverlongAddresses() {
        let longLocal = String(repeating: "a", count: 65) + "@example.com"
        #expect(!EmailAddress.isValid(longLocal))

        let longDomain = "a@" + String(repeating: "b", count: 250) + ".com"
        #expect(!EmailAddress.isValid(longDomain))
    }
}
