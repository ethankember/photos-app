import CloudCore
import Foundation
import Testing
@testable import ImmichAPI

@Suite struct OAuthTests {
    /// RFC 7636, appendix B.
    @Test func codeChallengeMatchesTheRFCExample() {
        #expect(ImmichOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomTokensAreURLSafeAndFresh() {
        let first = ImmichOAuth.randomToken()
        let second = ImmichOAuth.randomToken()
        #expect(first.count == 43)
        #expect(first != second)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        #expect(first.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test(arguments: [
        "app.immich:///oauth-callback?code=abc&state=s1",
        "app.immich:/oauth-callback?code=abc&state=s1",
        "app.immich://oauth-callback?code=abc&state=s1",
    ])
    func callbackIsSentWithTheExactRedirect(callback: String) throws {
        let url = try ImmichOAuth.callbackForServer(URL(string: callback)!, expectedState: "s1")
        #expect(url == "app.immich:///oauth-callback?code=abc&state=s1")
    }

    @Test func callbackKeepsPercentEncoding() throws {
        let url = try ImmichOAuth.callbackForServer(URL(string: "app.immich:///oauth-callback?code=a%2Fb&state=s1&iss=https%3A%2F%2Fauth.example.com")!, expectedState: "s1")
        #expect(url == "app.immich:///oauth-callback?code=a%2Fb&state=s1&iss=https%3A%2F%2Fauth.example.com")
    }

    @Test func callbackWithAnotherStateIsRefused() {
        #expect(throws: CloudError.self) {
            try ImmichOAuth.callbackForServer(URL(string: "app.immich:///oauth-callback?code=abc&state=other")!, expectedState: "s1")
        }
    }

    @Test func callbackWithoutCodeIsRefused() {
        #expect(throws: CloudError.self) {
            try ImmichOAuth.callbackForServer(URL(string: "app.immich:///oauth-callback?state=s1")!, expectedState: "s1")
        }
    }

    @Test func identityProviderErrorIsShown() {
        do {
            _ = try ImmichOAuth.callbackForServer(
                URL(string: "app.immich:///oauth-callback?error=access_denied&error_description=Not%20allowed&state=s1")!,
                expectedState: "s1"
            )
            Issue.record("expected an error")
        } catch let error as CloudError {
            #expect(error.kind == .unauthorized)
            #expect(error.message.contains("Not allowed"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func serverErrorBodyIsReadable() {
        let body = Data(#"{"message":"User does not exist and auto registering is disabled.","error":"Bad Request","statusCode":400}"#.utf8)
        let error = APIError.from(statusCode: 400, body: body, operation: "finish single sign-on")
        #expect(error.message == "Unexpected response 400 for finish single sign-on: User does not exist and auto registering is disabled.")
    }
}
