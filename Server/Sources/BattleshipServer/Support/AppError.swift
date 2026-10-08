import BattleshipAPI
import BattleshipCore
import Vapor

/// An error with a stable machine-readable code, rendered as `{"code": …, "message": …}`.
struct AppError: AbortError, Equatable {
    let status: HTTPResponseStatus
    let code: APIErrorCode
    let reason: String

    init(_ status: HTTPResponseStatus, _ code: APIErrorCode, _ reason: String) {
        self.status = status
        self.code = code
        self.reason = reason
    }

    static let unauthorized = AppError(.unauthorized, .unauthorized, "Sign in to continue.")
    static let invalidCredentials = AppError(.unauthorized, .invalidCredentials, "Incorrect username or password.")
    static let usernameTaken = AppError(.conflict, .usernameTaken, "That username is already taken.")
    static let rateLimited = AppError(.tooManyRequests, .rateLimited, "Too many attempts. Wait a minute and try again.")
    static let serverBusy = AppError(.tooManyRequests, .rateLimited, "The server is busy. Try again in a moment.")
    static let tooManySignInAttempts = AppError(.tooManyRequests, .rateLimited, "Too many sign-in attempts for this account. Try again in a few minutes.")
    static let tooManyNewGames = AppError(.tooManyRequests, .rateLimited, "You've started a lot of games recently. Wait a few minutes and try again.")
    static let gameNotFound = AppError(.notFound, .gameNotFound, "That game doesn't exist, or you're not playing in it.")
    static let playerNotFound = AppError(.notFound, .playerNotFound, "There's no player with that username.")
    static let cannotChallengeYourself = AppError(.badRequest, .cannotChallengeYourself, "You can't challenge yourself.")
    static let opponentStillHasTime = AppError(.conflict, .opponentStillHasTime, "Your opponent still has time to make their move.")
    static let playerBlocked = AppError(.conflict, .playerBlocked, "You've blocked this player. Unblock them under Profile to play them.")
    static let cannotBlockYourself = AppError(.badRequest, .badRequest, "You can't block or report yourself.")

    static let invalidIdentityToken = AppError(.unauthorized, .invalidIdentityToken, "That sign-in couldn't be verified. Please try again.")
    static let signupTicketUnknown = AppError(.badRequest, .signupTicketInvalid, "That sign-up has already been finished, or doesn't exist. Please sign in again.")
    static let signupTicketExpired = AppError(.gone, .signupTicketInvalid, "That sign-up took too long. Please sign in again.")

    static func signInUnavailable(_ provider: IdentityProvider) -> AppError {
        AppError(.notFound, .signInMethodUnavailable, "Sign in with \(provider.displayName) isn't set up on this server.")
    }

    static func identityCheckUnavailable(_ provider: IdentityProvider) -> AppError {
        AppError(.serviceUnavailable, .signInMethodUnavailable, "Couldn't reach \(provider.displayName) to check your sign-in. Try again in a moment.")
    }

    static func tooManyGames(limit: Int) -> AppError {
        AppError(.conflict, .tooManyGames, "You already have \(limit) games going. Finish or resign one first.")
    }

    static func challengeAlreadySent(to opponent: String) -> AppError {
        AppError(.conflict, .invalidGameState, "You've already challenged \(opponent). Wait for their answer, or withdraw that challenge first.")
    }

    static func challengeAlreadyReceived(from opponent: String) -> AppError {
        AppError(.conflict, .invalidGameState, "\(opponent) has already challenged you. Accept or decline their challenge in your lobby.")
    }

    static func tooManyPendingChallenges(for opponent: String) -> AppError {
        AppError(.conflict, .tooManyGames, "\(opponent) has too many challenges waiting for an answer. Try again later.")
    }

    static func invalidState(_ message: String) -> AppError {
        AppError(.conflict, .invalidGameState, message)
    }

    static func badRequest(_ message: String) -> AppError {
        AppError(.badRequest, .badRequest, message)
    }

    init(_ error: FleetError) {
        self.init(.unprocessableEntity, .invalidFleet, error.description)
    }

    init(_ error: BattleError) {
        switch error {
        case .gameOver:
            self.init(.conflict, .gameOver, "This game is already over.")
        case .notYourTurn:
            self.init(.conflict, .notYourTurn, "It's not your turn.")
        case let .outOfBounds(target):
            self.init(.badRequest, .outOfBounds, "\(target) is not on the board.")
        case let .alreadyTargeted(target):
            self.init(.conflict, .alreadyTargeted, "You already fired at \(target).")
        case .corrupted:
            self.init(.internalServerError, .internalError, "This game's data is damaged.")
        }
    }
}

/// Renders every error as the shared ``APIErrorBody`` JSON shape.
struct APIErrorMiddleware: AsyncMiddleware {
    let environment: Environment

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let (status, body) = describe(error)
            if status.code >= 500 {
                request.logger.report(error: error)
            }
            let response = Response(status: status)
            response.headers.contentType = .json
            response.body = .init(data: (try? APICoding.makeEncoder().encode(body)) ?? Data())
            if let abort = error as? any AbortError {
                for (name, value) in abort.headers where name.lowercased() != "content-type" {
                    response.headers.replaceOrAdd(name: name, value: value)
                }
            }
            return response
        }
    }

    private func describe(_ error: any Error) -> (HTTPResponseStatus, APIErrorBody) {
        switch error {
        case let error as AppError:
            return (error.status, APIErrorBody(code: error.code, message: error.reason))
        case let error as FleetError:
            let appError = AppError(error)
            return (appError.status, APIErrorBody(code: appError.code, message: appError.reason))
        case let error as BattleError:
            let appError = AppError(error)
            return (appError.status, APIErrorBody(code: appError.code, message: appError.reason))
        case let error as any AbortError:
            let code: APIErrorCode = switch error.status {
            case .unauthorized: .unauthorized
            case .forbidden: .forbidden
            case .notFound: .notFound
            case .tooManyRequests: .rateLimited
            default: error.status.code >= 500 ? .internalError : .badRequest
            }
            return (error.status, APIErrorBody(code: code, message: error.reason))
        default:
            let message = environment.isRelease ? "Something went wrong on our end." : String(describing: error)
            return (.internalServerError, APIErrorBody(code: .internalError, message: message))
        }
    }
}
