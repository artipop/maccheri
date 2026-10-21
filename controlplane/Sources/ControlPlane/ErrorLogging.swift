import Vapor

extension ErrorMiddleware {
    /// Vapor's default error middleware, except that it logs the path without the query: the
    /// signaling WebSocket carries its token there (``SignalingAPI``).
    static func redacting(environment: Environment) -> ErrorMiddleware {
        ErrorMiddleware { req, error in
            let status: HTTPResponseStatus
            let reason: String
            var headers: HTTPHeaders
            switch error {
            case let abort as any AbortError:
                (reason, status, headers) = (abort.reason, abort.status, abort.headers)
            default:
                reason = environment.isRelease ? "Something went wrong." : String(describing: error)
                (status, headers) = (.internalServerError, [:])
            }
            req.logger.report(error: error, metadata: [
                "method": "\(req.method.rawValue)",
                "path": "\(req.url.path)",
            ])

            struct ErrorResponse: Encodable { var error = true; var reason: String }
            var body = req.byteBufferAllocator.buffer(capacity: 0)
            do {
                try ContentConfiguration.global.requireEncoder(for: .json).encode(ErrorResponse(reason: reason), to: &body, headers: &headers)
            } catch {
                body = req.byteBufferAllocator.buffer(string: reason)
                headers.contentType = .plainText
            }
            return Response(status: status, headers: headers, body: .init(buffer: body))
        }
    }
}
