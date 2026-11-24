import Foundation
import Testing
@testable import RexplainCore

final class MockSessionHandle: ModelSessionHandle, @unchecked Sendable {
    let contextSize: Int
    var isResponding: Bool = false
    var prewarmedPrefixes: [String?] = []
    var recordedPrompts: [(prompt: String, maxTokens: Int)] = []
    var tokenEstimator: @Sendable (String) -> Int?
    var streamBehavior: @Sendable (String) -> AsyncThrowingStream<ModelStreamChunk, Error>

    init(
        contextSize: Int = OnDeviceLimits.defaultContextTokens,
        tokenEstimator: @escaping @Sendable (String) -> Int? = { $0.count / 4 },
        streamBehavior: @escaping @Sendable (String) -> AsyncThrowingStream<ModelStreamChunk, Error> = { _ in
            AsyncThrowingStream { c in
                c.yield(.delta("1. Step one.\n\n"))
                c.yield(.delta("2. Step one ⇒ Step two."))
                c.finish()
            }
        }
    ) {
        self.contextSize = contextSize
        self.tokenEstimator = tokenEstimator
        self.streamBehavior = streamBehavior
    }

    func prewarm(promptPrefix: String?) async {
        prewarmedPrefixes.append(promptPrefix)
    }

    func estimateInputTokens(for prompt: String) async -> Int? {
        tokenEstimator(prompt)
    }

    func streamResponse(to prompt: String, maxResponseTokens: Int) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        recordedPrompts.append((prompt, maxResponseTokens))
        isResponding = true
        let inner = streamBehavior(prompt)
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { self.isResponding = false }
                do {
                    for try await item in inner {
                        try Task.checkCancellation()
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

final class MockBackend: LanguageModelBackend, @unchecked Sendable {
    var localStatus: LocalModelStatus
    var createdSessions: [MockSessionHandle] = []
    var sessionFactory: @Sendable () -> MockSessionHandle

    init(
        localStatus: LocalModelStatus = LocalModelStatus(available: true, detailMessage: "OK"),
        sessionFactory: @escaping @Sendable () -> MockSessionHandle = { MockSessionHandle() }
    ) {
        self.localStatus = localStatus
        self.sessionFactory = sessionFactory
    }

    func availabilityStatus() -> LocalModelStatus {
        localStatus
    }

    func makeSession(instructions: String) throws -> any ModelSessionHandle {
        guard localStatus.available else {
            throw EngineFailure(code: .serviceUnavailable, message: localStatus.detailMessage)
        }
        let session = sessionFactory()
        createdSessions.append(session)
        return session
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RexplainEvent] = []

    var events: [RexplainEvent] {
        lock.lock()
        let copy = stored
        lock.unlock()
        return copy
    }

    func append(_ event: RexplainEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }
}

@Suite("ExplainEngine Prewarming, Budgeting, Streaming & Cancellation")
struct ExplainEngineTests {
    @Test("Prewarms stable prefix, reuses prepared session, and allocates full first-principles token budget")
    func prewarmAndStream() async {
        let backend = MockBackend()
        let engine = ExplainEngine(backend: backend)

        let prepCollector = EventCollector()
        await engine.prepare { prepCollector.append($0) }
        #expect(prepCollector.events.first?.type == "ready")
        #expect(prepCollector.events.first?.prewarmed == true)
        #expect(backend.createdSessions.count == 1)
        #expect(backend.createdSessions[0].prewarmedPrefixes == [PromptTemplates.stablePrewarmPrefix])

        let explainCollector = EventCollector()
        await engine.explain(text: "A mutex guards shared state.", detail: .firstPrinciples) {
            explainCollector.append($0)
        }

        #expect(backend.createdSessions.count == 1)
        #expect(explainCollector.events.contains { $0.type == "started" && $0.prewarmed == true })
        #expect(explainCollector.events.contains { $0.type == "delta" })
        #expect(explainCollector.events.last?.type == "completed")
        #expect((backend.createdSessions[0].recordedPrompts.first?.maxTokens ?? 0) >= 2_000)
    }

    @Test("Empty selection, oversized selection, and context window overflow behave cleanly")
    func selectionAndContextBounds() async {
        let backend = MockBackend {
            MockSessionHandle(contextSize: 500, tokenEstimator: { $0.contains("OVERFLOW_MARKER") ? 450 : 120 })
        }
        let engine = ExplainEngine(backend: backend)

        let emptyCollector = EventCollector()
        await engine.explain(text: "   \n ", detail: .compact) { emptyCollector.append($0) }
        #expect(emptyCollector.events.first?.errorCode == .emptySelection)

        let tooLargeCollector = EventCollector()
        await engine.explain(text: String(repeating: "x", count: 10_005), detail: .compact) { tooLargeCollector.append($0) }
        #expect(tooLargeCollector.events.first?.errorCode == .selectionTooLarge)

        let overflowCollector = EventCollector()
        await engine.explain(text: "OVERFLOW_MARKER", detail: .compact) { overflowCollector.append($0) }
        #expect(overflowCollector.events.first?.errorCode == .contextSizeExceeded)

        let okCollector = EventCollector()
        await engine.explain(text: "Short selection", detail: .compact) { okCollector.append($0) }
        #expect(okCollector.events.last?.type == "completed")
    }

    @Test("Snapshot replacement, concurrent requests, and cancellation behave accurately")
    func replaceConcurrentAndCancel() async {
        let backend = MockBackend {
            MockSessionHandle(streamBehavior: { _ in
                AsyncThrowingStream { c in
                    c.yield(.delta("draft"))
                    c.yield(.replace("1. Clean final step."))
                    c.finish()
                }
            })
        }
        let engine = ExplainEngine(backend: backend)

        let replaceCollector = EventCollector()
        await engine.explain(text: "Concept", detail: .compact) { replaceCollector.append($0) }
        #expect(replaceCollector.events.contains { $0.type == "replace" && $0.text == "1. Clean final step." })

        let slowBackend = MockBackend {
            MockSessionHandle(streamBehavior: { _ in
                AsyncThrowingStream { c in
                    let t = Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        c.finish(throwing: CancellationError())
                    }
                    c.onTermination = { @Sendable _ in t.cancel() }
                }
            })
        }
        let slowEngine = ExplainEngine(backend: slowBackend)
        let cancelCollector = EventCollector()
        let runTask = Task {
            await slowEngine.explain(text: "Concept", detail: .compact) { cancelCollector.append($0) }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let concurrentCollector = EventCollector()
        await slowEngine.explain(text: "Other", detail: .compact) { concurrentCollector.append($0) }
        #expect(concurrentCollector.events.first?.errorCode == .concurrentRequests)

        await slowEngine.cancelActive()
        await runTask.value
        #expect(cancelCollector.events.contains { $0.type == "cancelled" })
    }

    @Test("Engine propagates backend badge and one-time firstRunHint on started event")
    func backendBadgeAndHint() async {
        let hintEngine = ExplainEngine(backend: MockBackend()) { "First run tip!" }
        let collector = EventCollector()
        await hintEngine.explain(text: "Hash map", detail: .compact) { collector.append($0) }
        let started = collector.events.first { $0.type == "started" }
        #expect(started?.backend == .fmf)
        #expect(started?.modelLabel == "On-device")
        #expect(started?.hint == "First run tip!")
    }
}
