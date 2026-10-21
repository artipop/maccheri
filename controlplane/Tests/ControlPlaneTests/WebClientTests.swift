import XCTVapor
@testable import ControlPlane

final class WebClientTests: ControlPlaneTestCase {
    func testServesFilesAndFallsBackToIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<!doctype html>index".write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: directory.appendingPathComponent("assets/app.js"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await restart { $0.publicDirectory = directory.path }

        try await app.test(.GET, "/") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "<!doctype html>index")
        }
        try await app.test(.GET, "assets/app.js") { res async in
            XCTAssertEqual(res.body.string, "console.log(1)")
        }
        try await app.test(.GET, "sessions/123") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "<!doctype html>index", "client-side routes get index.html")
        }
        try await app.test(.GET, "v1/nope") { res async in
            XCTAssertEqual(res.status, .notFound, "the API never falls back to the web client")
        }
        try await app.test(.GET, "healthz") { res async in
            XCTAssertEqual(res.body.string, "ok")
        }
    }
}
