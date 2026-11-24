import Foundation
import Testing
@testable import RexplainCore

@Suite("Protocol Serialization & Worker Commands")
struct WorkerProtocolTests {
    @Test("WorkerCommand JSON round-trip preserves fields")
    func workerCommandRoundTrip() throws {
        let cmd = WorkerCommand(cmd: "explain", detail: .firstPrinciples, text: "Bayes rule")
        let data = try JSONEncoder().encode(cmd)
        let decoded = try JSONDecoder().decode(WorkerCommand.self, from: data)
        #expect(decoded == cmd)
    }

    @Test("RexplainEvent JSON round-trip preserves fields")
    func eventRoundTrip() throws {
        let event = RexplainEvent.message("ready", detail: .standard, prewarmed: true, contextSize: 4096)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RexplainEvent.self, from: data)
        #expect(decoded.detail == .standard)
        #expect(decoded.prewarmed == true)
        #expect(decoded.contextSize == 4096)
    }
}
