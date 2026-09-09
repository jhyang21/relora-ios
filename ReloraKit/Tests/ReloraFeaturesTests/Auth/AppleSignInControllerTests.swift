import AuthenticationServices
import Foundation
import Testing
import ReloraServices
@testable import ReloraFeatures

/// The parts of the Apple flow that can be driven without Apple.
///
/// A successful authorization cannot be built here: `ASAuthorization` has no
/// public initializer, so the token-to-session half is covered a layer down by
/// `IdentityControllerTests` and the rest by the device pass. What is testable
/// is the part that carries the security: the nonce, and the difference
/// between a cancelled sheet and a real failure.
@MainActor
@Suite("AppleSignInController")
struct AppleSignInControllerTests {

    private func makeController() -> AppleSignInController {
        AppleSignInController(identity: makeNoOpIdentityController())
    }

    private func makeRequest() -> ASAuthorizationAppleIDRequest {
        ASAuthorizationAppleIDProvider().createRequest()
    }

    @Test("The request carries a hashed nonce, never the raw one")
    func hashesTheNonce() throws {
        let request = makeRequest()
        makeController().prepare(request)

        let nonce = try #require(request.nonce)
        // SHA-256 as lowercase hex: 64 characters, and nothing outside them.
        #expect(nonce.count == 64)
        #expect(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// The whole point of a nonce. Reusing one across attempts would let a
    /// token captured from the first attempt be replayed into the second.
    @Test("Every attempt gets its own nonce")
    func mintsAFreshNonceEachTime() {
        let controller = makeController()
        let first = makeRequest()
        let second = makeRequest()

        controller.prepare(first)
        controller.prepare(second)

        #expect(first.nonce != second.nonce)
    }

    @Test("The request asks for the address and nothing else")
    func asksForOneScope() {
        let request = makeRequest()
        makeController().prepare(request)

        #expect(request.requestedScopes == [.email])
    }

    /// Backing out of Apple's sheet is a decision, not a fault. An error
    /// message under the button would tell the user off for closing something
    /// they chose to close.
    @Test("A cancelled sheet says nothing")
    func cancellationIsSilent() async {
        let controller = makeController()
        let opened = await controller.complete(.failure(ASAuthorizationError(.canceled)))

        #expect(opened == false)
        #expect(controller.error == nil)
    }

    @Test("A real failure is reported, and never in the framework's words")
    func realFailureIsReported() async throws {
        let controller = makeController()
        let opened = await controller.complete(.failure(ASAuthorizationError(.failed)))

        #expect(opened == false)
        let message = try #require(controller.error?.message)
        #expect(!message.isEmpty)
        #expect(!message.lowercased().contains("asauthorization"))
    }

    /// `prepare` clears whatever the last attempt left behind, so a retry does
    /// not start under the error that made the user retry.
    @Test("Preparing a new attempt clears the last failure")
    func preparingClearsTheError() async {
        let controller = makeController()
        _ = await controller.complete(.failure(ASAuthorizationError(.failed)))
        #expect(controller.error != nil)

        controller.prepare(makeRequest())

        #expect(controller.error == nil)
    }
}
