import Foundation
import Testing
import ReloraServices
@testable import ReloraFeatures

/// The root decision, and the sign-out bug it exists to prevent.
@Suite("Root gate")
struct RootGateTests {
    @Test("Nothing renders until identity has been restored")
    func launchingBeforeBootstrap() {
        #expect(
            RootGate.destination(
                identity: .unresolved,
                isBootstrapped: false,
                onboardingCompleted: false
            ) == .launching
        )
        // Even a finished onboarding waits: the pre-bootstrap `.unresolved` is
        // indistinguishable from a resolved one, and guessing costs a flash of
        // the wrong screen.
        #expect(
            RootGate.destination(
                identity: .unresolved,
                isBootstrapped: false,
                onboardingCompleted: true
            ) == .launching
        )
    }

    @Test("A fresh install starts in onboarding")
    func freshInstall() {
        #expect(
            RootGate.destination(
                identity: .unresolved,
                isBootstrapped: true,
                onboardingCompleted: false
            ) == .onboarding
        )
    }

    /// The regression this rebuild exists to fix: signing out returns identity
    /// to `.unresolved`, and RN sent that user back to the welcome flow.
    @Test("Signing out lands on a signed-out Home, never onboarding")
    func signedOutGoesHome() {
        #expect(
            RootGate.destination(
                identity: .unresolved,
                isBootstrapped: true,
                onboardingCompleted: true
            ) == .home
        )
    }

    @Test("A real account always goes Home, whatever the onboarding flag says")
    func accountAlwaysGoesHome() {
        let account = Identity.account(userID: "acct-1", email: "person@example.com")
        #expect(
            RootGate.destination(identity: account, isBootstrapped: true, onboardingCompleted: false) == .home
        )
        #expect(
            RootGate.destination(identity: account, isBootstrapped: true, onboardingCompleted: true) == .home
        )
    }

    /// M10: LetsTryIt mints a local guest identity to own the tutorial
    /// example, and GetStarted does the same for "Enter Relora"/"See your
    /// example" — both while onboarding is still on screen and the
    /// completion flag is still false. A guest or anonymous identity must
    /// not, by itself, end onboarding early.
    @Test("A guest or anonymous identity stays in onboarding until the flag says done")
    func guestIdentityStaysInOnboardingUntilFlagged() {
        let identities: [Identity] = [
            .localGuest(userID: "local-guest-1"),
            .anonymous(userID: "anon-1")
        ]

        for identity in identities {
            #expect(
                RootGate.destination(identity: identity, isBootstrapped: true, onboardingCompleted: false)
                    == .onboarding
            )
            #expect(
                RootGate.destination(identity: identity, isBootstrapped: true, onboardingCompleted: true)
                    == .home
            )
        }
    }
}

@Suite("Deep links")
struct DeepLinkTests {
    @Test("A contact link carries its id")
    func contactLink() {
        #expect(
            ReloraDeepLink.classify(URL(string: "relora://contact/abc-123")!)
                == .contact(id: "abc-123")
        )
    }

    @Test("Spellings with an extra slash or a trailing one still resolve")
    func contactLinkSpellings() {
        #expect(
            ReloraDeepLink.classify(URL(string: "relora:///contact/abc-123")!)
                == .contact(id: "abc-123")
        )
        #expect(
            ReloraDeepLink.classify(URL(string: "relora://contact/abc-123/")!)
                == .contact(id: "abc-123")
        )
    }

    @Test("A password-recovery link is an auth link, not a route")
    func recoveryLink() {
        let url = URL(string: "relora://reset-password#access_token=a&refresh_token=b&type=recovery")!
        #expect(ReloraDeepLink.classify(url) == .auth(isPasswordRecovery: true))
    }

    @Test("Anything else is unknown rather than a guess")
    func unknownLink() {
        #expect(ReloraDeepLink.classify(URL(string: "relora://contact")!) == .unknown)
        #expect(ReloraDeepLink.classify(URL(string: "relora://elsewhere/1")!) == .unknown)
        #expect(ReloraDeepLink.classify(URL(string: "https://example.com/contact/1")!) == .unknown)
    }
}
