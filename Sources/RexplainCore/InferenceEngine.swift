import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum ModelStreamChunk: Sendable, Equatable {
    case delta(String)
    case replace(String)
}

public struct EngineFailure: Error, Sendable, Equatable {
    public var code: RexplainErrorCode
    public var message: String

    public init(code: RexplainErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public protocol ModelSessionHandle: Sendable {
    var isResponding: Bool { get }
    var contextSize: Int { get }
    func prewarm(promptPrefix: String?) async
    func estimateInputTokens(for prompt: String) async -> Int?
    func streamResponse(to prompt: String, maxResponseTokens: Int) -> AsyncThrowingStream<ModelStreamChunk, Error>
}

public protocol LanguageModelBackend: Sendable {
    var backendKind: ModelBackendKind { get }
    var displayBadge: String { get }
    var activeModelName: String { get }
    var maximumSelectionCharacters: Int { get }
    var supportsPrewarm: Bool { get }
    func availabilityStatus() -> LocalModelStatus
    func makeSession(instructions: String) throws -> any ModelSessionHandle
}

public extension LanguageModelBackend {
    var backendKind: ModelBackendKind { .fmf }
    var displayBadge: String { "On-device" }
    var activeModelName: String { "Apple Foundation Model" }
    var maximumSelectionCharacters: Int { OnDeviceLimits.maximumSelectionCharacters }
    var supportsPrewarm: Bool { true }
}

public enum BackendFactory {
    public static func makeBackend(
        config: RexplainConfig,
        inspector: ModelAvailabilityInspector = ModelAvailabilityInspector(),
        locator: MLXExecutableLocator = MLXExecutableLocator()
    ) -> any LanguageModelBackend {
        switch config.backend {
        case .fmf:
            return AppleFoundationModelsBackend(inspector: inspector)
        case .mlx:
            return MLXBackend(
                model: config.mlxModel ?? "",
                runner: config.mlxRunner,
                customCommand: config.mlxCommand,
                locator: locator
            )
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private final class AppleLocalSessionHandle: ModelSessionHandle, @unchecked Sendable {
    let contextSize: Int
    private let model: SystemLanguageModel
    private let session: LanguageModelSession

    init(model: SystemLanguageModel, instructions: String) {
        self.model = model
        self.contextSize = model.contextSize
        self.session = LanguageModelSession(model: model, instructions: instructions)
    }

    var isResponding: Bool {
        session.isResponding
    }

    func prewarm(promptPrefix: String?) async {
        session.prewarm(promptPrefix: promptPrefix.map { Prompt($0) })
    }

    func estimateInputTokens(for prompt: String) async -> Int? {
        guard #available(macOS 26.4, *) else { return nil }
        do {
            return try await model.tokenCount(for: session.transcript) + model.tokenCount(for: Prompt(prompt))
        } catch {
            return nil
        }
    }

    func streamResponse(to prompt: String, maxResponseTokens: Int) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let options = GenerationOptions(
                        samplingMode: .random(probabilityThreshold: 0.9),
                        temperature: 0.45,
                        maximumResponseTokens: maxResponseTokens
                    )
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        let current = snapshot.content
                        if current.hasPrefix(previous) {
                            let delta = String(current.dropFirst(previous.count))
                            if !delta.isEmpty { continuation.yield(.delta(delta)) }
                        } else {
                            continuation.yield(.replace(current))
                        }
                        previous = current
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapAppleError(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@available(macOS 26.0, *)
private func mapAppleError(_ error: Error) -> Error {
    if error is CancellationError { return CancellationError() }
    if let existing = error as? EngineFailure { return existing }

    if #available(macOS 27.0, *) {
        if let lmErr = error as? LanguageModelError {
            switch lmErr {
            case .contextSizeExceeded(let info):
                return EngineFailure(code: .contextSizeExceeded, message: "Context window exceeded (\(info.tokenCount)/\(info.contextSize) tokens). Select a shorter passage.")
            case .rateLimited(let info):
                return EngineFailure(code: .rateLimited, message: "Model rate limit reached: \(info.debugDescription)")
            case .guardrailViolation(let info):
                return EngineFailure(code: .guardrailViolation, message: "Content triggered Apple Foundation Models safety guardrails: \(info.debugDescription)")
            case .refusal(let info):
                return EngineFailure(code: .refusal, message: "Model declined to answer this prompt: \(info.debugDescription)")
            case .timeout(let info):
                return EngineFailure(code: .serviceUnavailable, message: "On-device inference timed out: \(info.debugDescription)")
            case .unsupportedCapability(let info):
                return EngineFailure(code: .internalError, message: "Unsupported capability: \(info.debugDescription)")
            case .unsupportedTranscriptContent(let info):
                return EngineFailure(code: .internalError, message: "Unsupported transcript content: \(info.debugDescription)")
            case .unsupportedGenerationGuide(let info):
                return EngineFailure(code: .internalError, message: "Unsupported generation guide: \(info.debugDescription)")
            case .unsupportedLanguageOrLocale(let info):
                return EngineFailure(code: .internalError, message: "Unsupported language or locale: \(info.debugDescription)")
            @unknown default:
                return EngineFailure(code: .internalError, message: lmErr.localizedDescription)
            }
        }
        if let sessionErr = error as? LanguageModelSession.Error {
            switch sessionErr {
            case .concurrentRequests, .transcriptMutationWhileResponding:
                return EngineFailure(code: .concurrentRequests, message: "A request is already generating. Wait or cancel before starting another.")
            @unknown default:
                return EngineFailure(code: .internalError, message: sessionErr.localizedDescription)
            }
        }
        if let sysErr = error as? SystemLanguageModel.Error {
            switch sysErr {
            case .assetsUnavailable(let info):
                return EngineFailure(code: .modelNotReady, message: "On-device model assets are unavailable: \(info.debugDescription)")
            @unknown default:
                return EngineFailure(code: .modelNotReady, message: sysErr.localizedDescription)
            }
        }
    }

    if let genErr = error as? LanguageModelSession.GenerationError {
        switch genErr {
        case .exceededContextWindowSize(let ctx):
            return EngineFailure(code: .contextSizeExceeded, message: "Context window exceeded: \(ctx.debugDescription)")
        case .assetsUnavailable(let ctx):
            return EngineFailure(code: .modelNotReady, message: "On-device model assets unavailable: \(ctx.debugDescription)")
        case .rateLimited(let ctx):
            return EngineFailure(code: .rateLimited, message: "Rate limited: \(ctx.debugDescription)")
        case .concurrentRequests(let ctx):
            return EngineFailure(code: .concurrentRequests, message: "Concurrent requests not allowed: \(ctx.debugDescription)")
        case .guardrailViolation(let ctx):
            return EngineFailure(code: .guardrailViolation, message: "Safety guardrail violation: \(ctx.debugDescription)")
        case .refusal(_, let ctx):
            return EngineFailure(code: .refusal, message: "Model refused request: \(ctx.debugDescription)")
        case .unsupportedGuide(let ctx), .unsupportedLanguageOrLocale(let ctx), .decodingFailure(let ctx):
            return EngineFailure(code: .internalError, message: ctx.debugDescription)
        @unknown default:
            return EngineFailure(code: .internalError, message: genErr.localizedDescription)
        }
    }

    return EngineFailure(
        code: .internalError,
        message: error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
    )
}
#endif

public struct AppleFoundationModelsBackend: LanguageModelBackend {
    private let inspector: ModelAvailabilityInspector

    public init(inspector: ModelAvailabilityInspector = ModelAvailabilityInspector()) {
        self.inspector = inspector
    }

    public func availabilityStatus() -> LocalModelStatus {
        inspector.status()
    }

    public func makeSession(instructions: String) throws -> any ModelSessionHandle {
        let status = inspector.status()
        guard status.available else {
            let code = RexplainErrorCode(rawValue: status.reason?.rawValue ?? "") ?? .serviceUnavailable
            throw EngineFailure(code: code, message: status.detailMessage)
        }
        #if canImport(FoundationModels)
        return AppleLocalSessionHandle(model: SystemLanguageModel.default, instructions: instructions)
        #else
        throw EngineFailure(code: .serviceUnavailable, message: "Apple FoundationModels framework is unavailable.")
        #endif
    }
}

public actor ExplainEngine {
    private let backend: any LanguageModelBackend
    private let firstRunHintProvider: (@Sendable () -> String?)?
    private var preparedHandle: (any ModelSessionHandle)?
    private var isPrewarmed = false
    private var isGenerating = false
    private var activeTaskCanceller: (@Sendable () -> Void)?

    public init(
        backend: any LanguageModelBackend = AppleFoundationModelsBackend(),
        firstRunHintProvider: (@Sendable () -> String?)? = nil
    ) {
        self.backend = backend
        self.firstRunHintProvider = firstRunHintProvider
    }

    public func availabilityStatus() -> LocalModelStatus {
        backend.availabilityStatus()
    }

    public func prepare(emit: @escaping @Sendable (RexplainEvent) -> Void) async {
        guard !isGenerating else {
            emitError("A request is already generating.", code: .concurrentRequests, via: emit)
            return
        }

        if !backend.supportsPrewarm {
            let status = backend.availabilityStatus()
            guard status.available else {
                let fallback: RexplainErrorCode = backend.backendKind == .mlx ? .mlxUnavailable : .serviceUnavailable
                let code = RexplainErrorCode(rawValue: status.reason?.rawValue ?? "") ?? fallback
                emitError(status.detailMessage, code: code, via: emit)
                return
            }
            emitLifecycle("ready", prewarmed: false, contextSize: status.contextSize, via: emit)
            return
        }

        do {
            let handle = try backend.makeSession(instructions: PromptTemplates.systemInstructions)
            await handle.prewarm(promptPrefix: PromptTemplates.stablePrewarmPrefix)
            preparedHandle = handle
            isPrewarmed = true
            emitLifecycle("ready", prewarmed: true, contextSize: handle.contextSize, via: emit)
        } catch {
            emitFailure(error, via: emit)
        }
    }

    public func explain(
        text: String?,
        detail: DetailLevel,
        emit: @escaping @Sendable (RexplainEvent) -> Void
    ) async {
        guard let selected = text.trimmedOrNil else {
            emitError("No selected text was supplied.", code: .emptySelection, detail: detail, via: emit)
            return
        }
        let maxChars = backend.maximumSelectionCharacters
        guard selected.count <= maxChars else {
            let limitLabel = backend.backendKind == .fmf ? "on-device" : "local"
            emitError(
                "Selection (\(selected.count) chars) exceeds the \(maxChars)-character \(limitLabel) limit. Select a shorter passage.",
                code: .selectionTooLarge,
                detail: detail,
                via: emit
            )
            return
        }
        guard !isGenerating else {
            emitError("A request is already generating.", code: .concurrentRequests, detail: detail, via: emit)
            return
        }

        do {
            let (handle, usedPrewarm) = try takeOrCreateSession()
            let prompt = PromptTemplates.buildExplainPrompt(selection: selected, detail: detail)
            let tokenBudget = try await fitPromptToContextWindow(handle: handle, detail: detail, prompt: prompt)

            isGenerating = true
            defer {
                isGenerating = false
                activeTaskCanceller = nil
            }

            let hint = firstRunHintProvider?()
            emitLifecycle("started", detail: detail, prewarmed: usedPrewarm, contextSize: handle.contextSize, hint: hint, via: emit)

            let stream = handle.streamResponse(to: prompt, maxResponseTokens: tokenBudget)
            let generationTask = Task<Result<Void, Error>, Never> {
                do {
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        switch chunk {
                        case .delta(let delta):
                            emit(.message("delta", text: delta, detail: detail))
                        case .replace(let full):
                            emit(.message("replace", text: full, detail: detail))
                        }
                    }
                    try Task.checkCancellation()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }

            activeTaskCanceller = { generationTask.cancel() }
            switch await generationTask.value {
            case .success:
                emitLifecycle("completed", detail: detail, prewarmed: usedPrewarm, contextSize: handle.contextSize, via: emit)
            case .failure(let error):
                emitFailure(error, detail: detail, via: emit)
            }
        } catch {
            emitFailure(error, detail: detail, via: emit)
        }
    }

    public func cancelActive() {
        activeTaskCanceller?()
        activeTaskCanceller = nil
        isGenerating = false
    }

    private func takeOrCreateSession() throws -> (any ModelSessionHandle, Bool) {
        if let existing = preparedHandle {
            let used = isPrewarmed
            preparedHandle = nil
            isPrewarmed = false
            return (existing, used)
        }
        return (try backend.makeSession(instructions: PromptTemplates.systemInstructions), false)
    }

    private func emitLifecycle(
        _ type: String,
        detail: DetailLevel? = nil,
        text: String? = nil,
        prewarmed: Bool? = nil,
        contextSize: Int? = nil,
        errorCode: RexplainErrorCode? = nil,
        hint: String? = nil,
        via emit: @Sendable (RexplainEvent) -> Void
    ) {
        emit(.message(
            type,
            text: text,
            detail: detail,
            errorCode: errorCode,
            prewarmed: prewarmed,
            contextSize: contextSize,
            backend: backend.backendKind,
            modelLabel: backend.displayBadge,
            hint: hint
        ))
    }

    private func emitError(
        _ message: String,
        code: RexplainErrorCode,
        detail: DetailLevel? = nil,
        via emit: @Sendable (RexplainEvent) -> Void
    ) {
        emit(.message(
            "error",
            detail: detail,
            error: message,
            errorCode: code,
            backend: backend.backendKind,
            modelLabel: backend.displayBadge
        ))
    }

    private func emitFailure(
        _ error: Error,
        detail: DetailLevel? = nil,
        via emit: @Sendable (RexplainEvent) -> Void
    ) {
        if error is CancellationError {
            emitLifecycle("cancelled", detail: detail, text: "Generation cancelled.", errorCode: .cancelled, via: emit)
        } else if let failure = error as? EngineFailure {
            emitError(failure.message, code: failure.code, detail: detail, via: emit)
        } else {
            emitError(error.localizedDescription, code: .internalError, detail: detail, via: emit)
        }
    }

    private func fitPromptToContextWindow(
        handle: any ModelSessionHandle,
        detail: DetailLevel,
        prompt: String
    ) async throws -> Int {
        let safetyMax = detail.safetyMaxResponseTokens
        let contextLimit = handle.contextSize
        guard let currentTokens = await handle.estimateInputTokens(for: prompt) else {
            return safetyMax
        }
        if currentTokens > contextLimit - 192 {
            throw EngineFailure(
                code: .contextSizeExceeded,
                message: "Selection and instructions require ~\(currentTokens) tokens, exceeding the \(contextLimit)-token context window. Select a shorter passage."
            )
        }
        return min(safetyMax, max(256, contextLimit - currentTokens - 64))
    }
}
