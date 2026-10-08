import BattleshipAPI
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIError: Error, Sendable {
    /// The request never got an answer: offline, DNS failure, timeout…
    case transport(URLError)
    /// The server understood the request and refused it.
    case server(status: Int, body: APIErrorBody)
    /// No session, or the session token expired or was revoked. Sign in again.
    case unauthorized
    /// The server's answer could not be understood.
    case invalidResponse(String)

    /// The server's error code, if the server sent one.
    public var code: APIErrorCode? {
        switch self {
        case let .server(_, body): body.code
        case .unauthorized: .unauthorized
        case .transport, .invalidResponse: nil
        }
    }

    /// `true` for failures worth retrying later without changing anything.
    public var isConnectivityProblem: Bool {
        if case .transport = self { return true }
        if case let .server(status, _) = self { return status >= 500 }
        return false
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .transport(error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "You're offline. Check your connection and try again."
            case .timedOut:
                return "The server took too long to respond. Try again in a moment."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can't reach the Battleships server right now."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "Couldn't open a secure connection to the server."
            default:
                return "A network error occurred (\(error.code.rawValue))."
            }
        case let .server(_, body):
            return body.message
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .invalidResponse:
            return "The server sent a response the app didn't understand."
        }
    }
}
