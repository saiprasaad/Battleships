import BattleshipAPI
import BattleshipClient
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite("API client")
struct APIClientTests {
    @Test func eventsRequestUpgradesSchemeAndAuthenticates() throws {
        let client = APIClient(baseURL: URL(string: "https://api.example.com/battleships")!, token: "secret")
        let request = try #require(client.eventsRequest())
        #expect(request.url?.absoluteString == "wss://api.example.com/battleships/v1/events")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

        let local = APIClient(baseURL: URL(string: "http://localhost:8080")!, token: "t")
        #expect(local.eventsRequest()?.url?.absoluteString == "ws://localhost:8080/v1/events")
    }

    @Test func signedOutClientHasNoEventStream() {
        let client = APIClient(baseURL: URL(string: "http://localhost:8080")!)
        #expect(client.eventsRequest() == nil)
        client.token = "abc"
        #expect(client.eventsRequest() != nil)
        client.token = nil
        #expect(client.eventsRequest() == nil)
    }

    @Test func authenticatedCallsFailFastWithoutAToken() async {
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:9")!)
        await #expect(throws: APIError.self) { _ = try await client.games() }
    }

    @Test func unreachableServerIsAConnectivityProblem() async {
        // Port 9 (discard) is closed on test machines, so the connection is refused immediately.
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:9")!)
        do {
            _ = try await client.signIn(Credentials(username: "a", password: "b"))
            Issue.record("expected the request to fail")
        } catch let error as APIError {
            #expect(error.isConnectivityProblem)
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func errorMessagesComeFromTheServer() {
        let error = APIError.server(status: 409, body: APIErrorBody(code: .usernameTaken, message: "That username is taken."))
        #expect(error.errorDescription == "That username is taken.")
        #expect(error.code == .usernameTaken)
        #expect(!error.isConnectivityProblem)
    }
}
