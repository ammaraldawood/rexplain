import Foundation

public enum RexplainVersion {
    public static let current = "1.3.0"
}

public enum RexplainErrorCode: String, Codable, Equatable, Sendable {
    case emptySelection = "empty_selection"
    case selectionTooLarge = "selection_too_large"
    case deviceNotEligible = "device_not_eligible"
    case appleIntelligenceNotEnabled = "apple_intelligence_not_enabled"
    case modelNotReady = "model_not_ready"
    case systemNotReady = "system_not_ready"
    case serviceUnavailable = "service_unavailable"
    case mlxUnavailable = "mlx_unavailable"
    case invalidConfig = "invalid_config"
    case contextSizeExceeded = "context_size_exceeded"
    case rateLimited = "rate_limited"
    case guardrailViolation = "guardrail_violation"
    case refusal = "refusal"
    case concurrentRequests = "concurrent_requests"
    case cancelled = "cancelled"
    case invalidRequest = "invalid_request"
    case internalError = "internal_error"
}

public struct WorkerCommand: Codable, Equatable, Sendable {
    public var cmd: String
    public var detail: DetailLevel?
    public var text: String?

    public init(cmd: String, detail: DetailLevel? = nil, text: String? = nil) {
        self.cmd = cmd
        self.detail = detail
        self.text = text
    }
}

public struct RexplainEvent: Codable, Equatable, Sendable {
    public var type: String
    public var text: String?
    public var detail: DetailLevel?
    public var error: String?
    public var errorCode: RexplainErrorCode?
    public var prewarmed: Bool?
    public var contextSize: Int?
    public var backend: ModelBackendKind?
    public var modelLabel: String?
    public var hint: String?

    public init(
        type: String,
        text: String? = nil,
        detail: DetailLevel? = nil,
        error: String? = nil,
        errorCode: RexplainErrorCode? = nil,
        prewarmed: Bool? = nil,
        contextSize: Int? = nil,
        backend: ModelBackendKind? = nil,
        modelLabel: String? = nil,
        hint: String? = nil
    ) {
        self.type = type
        self.text = text
        self.detail = detail
        self.error = error
        self.errorCode = errorCode
        self.prewarmed = prewarmed
        self.contextSize = contextSize
        self.backend = backend
        self.modelLabel = modelLabel
        self.hint = hint
    }

    enum CodingKeys: String, CodingKey {
        case type, text, detail, error, prewarmed, backend, hint
        case errorCode = "error_code"
        case contextSize = "context_size"
        case modelLabel = "model_label"
    }

    public static func message(
        _ type: String,
        text: String? = nil,
        detail: DetailLevel? = nil,
        error: String? = nil,
        errorCode: RexplainErrorCode? = nil,
        prewarmed: Bool? = nil,
        contextSize: Int? = nil,
        backend: ModelBackendKind? = nil,
        modelLabel: String? = nil,
        hint: String? = nil
    ) -> RexplainEvent {
        RexplainEvent(
            type: type,
            text: text,
            detail: detail,
            error: error,
            errorCode: errorCode,
            prewarmed: prewarmed,
            contextSize: contextSize,
            backend: backend,
            modelLabel: modelLabel,
            hint: hint
        )
    }
}
