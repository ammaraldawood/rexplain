import Foundation
import Testing
@testable import RexplainCore

@Suite("Availability & Status")
struct OnDeviceStatusTests {
    @Test("Available on-device snapshot reports ready status, FMF badge, and three effort levels")
    func availableStatus() {
        let inspector = ModelAvailabilityInspector {
            SystemAvailabilitySnapshot(local: .available(contextSize: 4_096))
        }
        let status = inspector.status()
        #expect(status.available == true)
        #expect(status.reason == nil)
        #expect(status.contextSize == 4_096)

        let report = inspector.statusReport(
            version: "1.3.0",
            config: RexplainConfig(),
            configPath: "~/.config/rexplain/config.json",
            mlxStatus: MLXEnvironmentStatus(lmAvailable: true, vlmAvailable: false, lmPath: "/usr/local/bin/mlx_lm")
        )
        #expect(report.defaultDetail == .compact)
        #expect(report.activeBackend == .fmf)
        #expect(report.displayBadge == "On-device")
        #expect(report.details.count == 3)
        #expect(report.onDevice.available == true)
        #expect(report.mlx.lmAvailable == true)
    }

    @Test("Status report reflects Local MLX badge without calling it On-device")
    func mlxStatusReportBadge() {
        let inspector = ModelAvailabilityInspector {
            SystemAvailabilitySnapshot(local: .available(contextSize: 4_096))
        }
        let report = inspector.statusReport(
            config: RexplainConfig(backend: .mlx, mlxModel: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
            mlxStatus: MLXEnvironmentStatus(lmAvailable: false, vlmAvailable: false)
        )
        #expect(report.activeBackend == .mlx)
        #expect(report.displayBadge == "Local · Qwen2.5-0.5B-Instruct-4bit")
        #expect(report.activeModel == "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    }

    @Test("On-device unavailability states map to structured reasons")
    func unavailableStates() {
        let reasons: [(LocalUnavailableReason, String)] = [
            (.deviceNotEligible, "Device ineligible"),
            (.appleIntelligenceNotEnabled, "Turn on Apple Intelligence"),
            (.modelNotReady, "Model assets downloading"),
            (.systemNotReady, "System busy"),
            (.frameworkUnavailable, "No framework"),
        ]
        for (reason, message) in reasons {
            let inspector = ModelAvailabilityInspector {
                SystemAvailabilitySnapshot(local: .unavailable(reason, message))
            }
            let status = inspector.status()
            #expect(status.available == false)
            #expect(status.reason == reason)
            #expect(status.detailMessage == message)
        }
    }

    @Test("Live system inspector reports current Mac status safely")
    func liveInspectorSafe() {
        let report = ModelAvailabilityInspector().statusReport()
        #expect(report.details.count == 3)
        #expect(report.onDevice.contextSize > 0)
    }
}
