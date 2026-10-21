import Vapor

/// Serves the web client (`web/dist`) from the root: files as they are, and `index.html` for
/// any other GET outside the API so client-side routes survive a reload.
struct WebClient {
    static let reservedPrefixes = ["v1", "agent", "github", "healthz"]

    let directory: String

    func register(on app: Application) {
        let directory = directory.hasSuffix("/") ? directory : directory + "/"
        app.middleware.use(FileMiddleware(publicDirectory: directory, defaultFile: "index.html"))
        app.get(.catchall) { req async throws -> Response in
            guard let first = req.url.path.split(separator: "/").first.map(String.init),
                  Self.reservedPrefixes.contains(first)
            else {
                return try await req.fileio.asyncStreamFile(at: directory + "index.html")
            }
            throw Abort(.notFound)
        }
    }
}
