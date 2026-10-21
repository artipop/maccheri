import Testing
@testable import Smoke

@Test @MainActor func runsOnTheSimulator() {
    #expect(deviceSummary().hasPrefix("iOS"))
}
