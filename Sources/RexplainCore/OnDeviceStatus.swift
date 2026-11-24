import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum OnDeviceLimits {
    public static let maximumSelectionCharacters = 10_000
    public static let defaultContextTokens = 4_096
}

public enum LocalUnavailableReason: String, Codable, Equatable, Sendable {
    case deviceNotEligible = "device_not_eligible"
    case appleIntelligenceNotEnabled = "apple_intelligence_not_enabled"
    case modelNotReady = "model_not_ready"
    case systemNotReady = "system_not_ready"
    case frameworkUnavailable = "framework_unavailable"
    case mlxUnavailable = "mlx_unavailable"
    case invalidConfig = "invalid_config"
}

public struct LocalModelStatus: Codable, Equatable, Sendable {
    public var available: Bool
    public var reason: LocalUnavailableReason?
    public var detailMessage: String
    public var contextSize: Int

    public init(
        available: Bool,
        reason: LocalUnavailableReason? = nil,
        detailMessage: String,
        contextSize: Int = OnDeviceLimits.defaultContextTokens
    ) {
        self.available = available
        self.reason = reason
        self.detailMessage = detailMessage
        self.contextSize = contextSize
    }

    enum CodingKeys: String, CodingKey {
        case available, reason
        case detailMessage = "detail_message"
        case contextSize = "context_size"
    }
}

public struct DetailOptionSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var stepRange: String

    public init(id: String, title: String, subtitle: String, stepRange: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.stepRange = stepRange
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle
        case stepRange = "step_range"
    }
}

public struct RexplainStatusReport: Codable, Equatable, Sendable {
    public var version: String
    public var defaultDetail: DetailLevel
    public var activeBackend: ModelBackendKind
    public var activeModel: String
    public var displayBadge: String
    public var configPath: String
    public var onDevice: LocalModelStatus
    public var mlx: MLXEnvironmentStatus
    public var details: [DetailOptionSummary]

    public init(
        version: String,
        defaultDetail: DetailLevel,
        activeBackend: ModelBackendKind = .fmf,
        activeModel: String = "Apple Foundation Model",
        displayBadge: String = "On-device",
        configPath: String = "~/.config/rexplain/config.json",
        onDevice: LocalModelStatus,
        mlx: MLXEnvironmentStatus = MLXEnvironmentStatus(lmAvailable: false, vlmAvailable: false),
        details: [DetailOptionSummary]
    ) {
        self.version = version
        self.defaultDetail = defaultDetail
        self.activeBackend = activeBackend
        self.activeModel = activeModel
        self.displayBadge = displayBadge
        self.configPath = configPath
        self.onDevice = onDevice
        self.mlx = mlx
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case version, mlx, details
        case defaultDetail = "default_detail"
        case activeBackend = "active_backend"
        case activeModel = "active_model"
        case displayBadge = "display_badge"
        case configPath = "config_path"
        case onDevice = "on_device"
    }
}

public struct SystemAvailabilitySnapshot: Sendable {
    public enum LocalState: Sendable {
        case available(contextSize: Int)
        case unavailable(LocalUnavailableReason, String)
    }

    public var local: LocalState

    public init(local: LocalState) {
        self.local = local
    }

    public static func live() -> SystemAvailabilitySnapshot {
        #if canImport(FoundationModels)
        let localModel = SystemLanguageModel.default
        switch localModel.availability {
        case .available:
            return SystemAvailabilitySnapshot(local: .available(contextSize: localModel.contextSize))
        case .unavailable(let reason):
            let mapped: LocalState
            switch reason {
            case .deviceNotEligible:
                mapped = .unavailable(.deviceNotEligible, "This Mac is not eligible for Apple's on-device Foundation Model.")
            case .appleIntelligenceNotEnabled:
                mapped = .unavailable(.appleIntelligenceNotEnabled, "Apple Intelligence is disabled in System Settings → Apple Intelligence & Siri.")
            case .modelNotReady:
                mapped = .unavailable(.modelNotReady, "The on-device Foundation Model assets are still downloading or preparing.")
            @unknown default:
                mapped = .unavailable(.systemNotReady, "On-device model unavailable: \(String(describing: reason))")
            }
            return SystemAvailabilitySnapshot(local: mapped)
        @unknown default:
            return SystemAvailabilitySnapshot(local: .unavailable(.systemNotReady, "Unknown on-device Foundation Model availability state."))
        }
        #else
        return SystemAvailabilitySnapshot(
            local: .unavailable(.frameworkUnavailable, "Apple FoundationModels framework is not available on this platform.")
        )
        #endif
    }
}

public struct ModelAvailabilityInspector: Sendable {
    private let snapshotProvider: @Sendable () -> SystemAvailabilitySnapshot

    public init(
        snapshotProvider: @escaping @Sendable () -> SystemAvailabilitySnapshot = { SystemAvailabilitySnapshot.live() }
    ) {
        self.snapshotProvider = snapshotProvider
    }

    public func status() -> LocalModelStatus {
        switch snapshotProvider().local {
        case .available(let ctx):
            return LocalModelStatus(available: true, detailMessage: "On-device model ready (~\(ctx) tokens context).", contextSize: ctx)
        case .unavailable(let reason, let message):
            return LocalModelStatus(available: false, reason: reason, detailMessage: message)
        }
    }

    public func statusReport(
        version: String = RexplainVersion.current,
        config: RexplainConfig = RexplainConfig(),
        configPath: String = ConfigStore().displayPath,
        mlxStatus: MLXEnvironmentStatus = MLXExecutableLocator().environmentStatus()
    ) -> RexplainStatusReport {
        RexplainStatusReport(
            version: version,
            defaultDetail: .compact,
            activeBackend: config.backend,
            activeModel: config.activeModelDescription,
            displayBadge: config.displayBadge,
            configPath: configPath,
            onDevice: status(),
            mlx: mlxStatus,
            details: DetailLevel.allCases.map {
                DetailOptionSummary(id: $0.rawValue, title: $0.displayName, subtitle: $0.pickerSubtitle, stepRange: $0.stepRangeDescription)
            }
        )
    }
}
