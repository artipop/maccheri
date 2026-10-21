import Fluent
import MaccheriProtocol
import Vapor

/// `GET /v1/sessions/{id}/signal?role=&token=` WebSocket. See ``SignalingAPI``.
///
/// The token is in the query; nothing here logs the query (Vapor's route log prints the path only).
struct SignalingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Checked before the upgrade, so a refusal is a plain HTTP error the client can see.
        routes.get("v1", "sessions", ":id", "signal") { req async throws -> Response in
            let (session, role) = try await Self.authorize(req)
            let id = session.id!
            let hub = req.maccheri.signaling
            let db = req.db
            let logger = req.logger
            // The EventLoopFuture flavour: `onUpgrade` runs on the socket's event loop, so the frame
            // handlers are in place before the first frame can arrive.
            return req.webSocket(maxFrameSize: WebSocketMaxFrameSize(integerLiteral: SignalHub.maxFrameBytes)) { _, socket in
                hub.join(session: id, role: role, socket: socket, logger: logger)
                // The session may have ended between the check and the join.
                Task {
                    if let current = try? await SessionModel.find(id, on: db), !current.isActive {
                        hub.end(session: id, reason: current.message)
                    }
                }
            }
        }
    }

    private static func authorize(_ req: Request) async throws -> (SessionModel, SignalingRole) {
        guard let id = req.parameters.get("id", as: UUID.self),
              let role = req.query[String.self, at: "role"].flatMap(SignalingRole.init(rawValue:)),
              let token = req.query[String.self, at: "token"]
        else { throw Abort(.badRequest, reason: "role and token are required") }
        guard let session = try await SessionModel.find(id, on: req.db) else { throw Abort(.notFound) }
        guard Tokens.constantTimeEqual(token, session.token(for: role)) else { throw Abort(.forbidden) }
        switch session.state {
        case .starting, .ready: return (session, role)
        case .queued: throw Abort(.conflict, reason: "session has not started")
        case .ended, .failed: throw Abort(.gone, reason: "session is over")
        }
    }
}
