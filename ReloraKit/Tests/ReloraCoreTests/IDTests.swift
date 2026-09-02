import Testing
@testable import ReloraCore

@Suite("ReloraID")
struct IDTests {
    @Test("new() is a lowercase 36-character UUID v4 string")
    func newProducesLowercaseUUIDv4() {
        let id = ReloraID.new()

        #expect(id.count == 36)
        #expect(id == id.lowercased())

        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
        #expect(id.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("new() produces distinct values across calls")
    func newProducesDistinctValues() {
        let ids = (0..<50).map { _ in ReloraID.new() }
        #expect(Set(ids).count == ids.count)
    }
}
