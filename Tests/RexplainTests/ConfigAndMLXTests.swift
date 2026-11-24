import Foundation
import Testing
@testable import RexplainCore

@Suite("Config Persistence, HF Cache Discovery & MLX Backend")
struct ConfigAndMLXTests {
    private func withTempDir(_ prefix: String, _ body: (URL) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try body(tempDir)
    }

    private func withTempDirAsync(_ prefix: String, _ body: (URL) async throws -> Void) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try await body(tempDir)
    }

    @Test("ConfigStore saves with 0600 permissions, preserves minimal JSON inference, and applies override precedence")
    func configPersistenceAndPrecedence() throws {
        try withTempDir("rexplain-cfg") { tempDir in
            let configURL = tempDir.appendingPathComponent("nested/config.json")
            let store = ConfigStore(configURL: configURL)

            let initial = try store.load()
            #expect(initial == RexplainConfig())
            #expect(initial.displayBadge == "On-device")

            let mlxConfig = RexplainConfig(
                backend: .mlx,
                mlxModel: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                mlxRunner: .auto,
                firstRunHintShown: true
            )
            try store.save(mlxConfig)

            let perms = (try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue
            #expect(perms == 0o600)
            #expect(try store.load() == mlxConfig)
            #expect(mlxConfig.displayBadge == "Local · Qwen2.5-0.5B-Instruct-4bit")

            let minimalURL = tempDir.appendingPathComponent("minimal.json")
            try #"{"mlx_model":"mlx-community/Phi-4-mini-instruct-4bit"}"#.write(to: minimalURL, atomically: true, encoding: .utf8)
            let inferred = try ConfigStore(configURL: minimalURL).load()
            #expect(inferred.backend == .mlx)
            #expect(inferred.mlxModel == "mlx-community/Phi-4-mini-instruct-4bit")
            #expect(inferred.displayBadge == "Local · Phi-4-mini-instruct-4bit")

            let env = ["REXPLAIN_MODEL": "env-org/env-model", "REXPLAIN_MLX_RUNNER": "mlx_vlm"]
            let resolvedEnvOnly = try store.resolve(overrides: ConfigOverrides(), environment: env)
            #expect(resolvedEnvOnly.config.backend == .mlx)
            #expect(resolvedEnvOnly.config.mlxModel == "env-org/env-model")
            #expect(resolvedEnvOnly.config.mlxRunner == .mlxVLM)
            #expect(resolvedEnvOnly.hasExplicitOverride == true)

            let resolvedCLI = try store.resolve(overrides: ConfigOverrides(backend: .fmf, model: "cli-ignored-when-fmf-explicit"), environment: env)
            #expect(resolvedCLI.config.backend == .fmf)
            #expect(resolvedCLI.hasExplicitOverride == true)

            let resolvedCLIModel = try store.resolve(overrides: ConfigOverrides(model: "cli-org/cli-model", mlxRunner: .mlxLM), environment: env)
            #expect(resolvedCLIModel.config.backend == .mlx)
            #expect(resolvedCLIModel.config.mlxModel == "cli-org/cli-model")
            #expect(resolvedCLIModel.config.mlxRunner == .mlxLM)
        }
    }

    @Test("One-time first-run hint emits once on default FMF and stays suppressed afterwards or on overrides")
    func firstRunHintOnce() throws {
        try withTempDir("rexplain-hint") { tempDir in
            let store = ConfigStore(configURL: tempDir.appendingPathComponent("config.json"))
            let resolved = try store.resolve(environment: [:])

            #expect(store.consumeFirstRunHintIfNeeded(resolved: resolved.config, hasExplicitOverride: true) == nil)

            let firstHint = store.consumeFirstRunHintIfNeeded(resolved: resolved.config, hasExplicitOverride: false)
            #expect(firstHint?.contains("Apple On-device (FMF)") == true)
            #expect(try store.load().firstRunHintShown == true)

            let resolvedSecond = try store.resolve(environment: [:])
            #expect(store.consumeFirstRunHintIfNeeded(resolved: resolvedSecond.config, hasExplicitOverride: false) == nil)
        }
    }

    @Test("Hugging Face cache discovery parses models, VLM vision_config, and context size")
    func hfCacheDiscovery() throws {
        try withTempDir("rexplain-hf") { tempHub in
            let lmSnap = tempHub.appendingPathComponent("models--acme--tiny-lm/snapshots/abc123")
            try FileManager.default.createDirectory(at: lmSnap, withIntermediateDirectories: true)
            try #"{"model_type":"qwen2","max_position_embeddings":8192}"#
                .write(to: lmSnap.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

            let vlmSnap = tempHub.appendingPathComponent("models--mlx-community--gemma-4-e4b-it-4bit/snapshots/def456")
            try FileManager.default.createDirectory(at: vlmSnap, withIntermediateDirectories: true)
            try #"{"model_type":"gemma4","vision_config":{"hidden_size":1152},"text_config":{"max_position_embeddings":32768}}"#
                .write(to: vlmSnap.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

            try FileManager.default.createDirectory(at: tempHub.appendingPathComponent("models--broken--no-config/snapshots/000"), withIntermediateDirectories: true)

            let discovered = MLXCacheDiscovery.discover(hubURL: tempHub)
            #expect(discovered.count == 2)
            #expect(discovered[0].id == "mlx-community/gemma-4-e4b-it-4bit")
            #expect(discovered[0].isMLXCommunity == true)
            #expect(discovered[0].suggestedRunner == .mlxVLM)
            #expect(discovered[0].contextSize == 32_768)

            #expect(discovered[1].id == "acme/tiny-lm")
            #expect(discovered[1].isMLXCommunity == false)
            #expect(discovered[1].suggestedRunner == .mlxLM)
            #expect(discovered[1].contextSize == 8_192)
        }
    }

    @Test("MLXExecutableLocator parses direct Python, env Python, and non-Python shebangs")
    func parsePythonShebangs() throws {
        try withTempDir("rexplain-shebang") { tempDir in
            let directPy = tempDir.appendingPathComponent("mlx_lm.generate")
            try "#!/opt/tools/mlx-lm/bin/python3.14 -s\nprint('hi')\n".write(to: directPy, atomically: true, encoding: .utf8)

            let envPy = tempDir.appendingPathComponent("mlx_vlm.generate")
            try "#!/usr/bin/env python3\nprint('hi')\n".write(to: envPy, atomically: true, encoding: .utf8)

            let shellScript = tempDir.appendingPathComponent("wrapper.sh")
            try "#!/bin/sh\necho hi\n".write(to: shellScript, atomically: true, encoding: .utf8)

            let locator = MLXExecutableLocator(environment: ["PATH": tempDir.path])
            let directParsed = locator.parsePythonShebang(at: directPy.path)
            #expect(directParsed?.executable == "/opt/tools/mlx-lm/bin/python3.14")
            #expect(directParsed?.prefixArgs == ["-s"])

            let envParsed = locator.parsePythonShebang(at: envPy.path)
            #expect(envParsed?.executable == "/usr/bin/env")
            #expect(envParsed?.prefixArgs == ["python3"])

            #expect(locator.parsePythonShebang(at: shellScript.path) == nil)
        }
    }

    @Test("MLXBackend streams direct CLI output, handles auto fallback from mlx_lm to mlx_vlm, and cancels cleanly")
    func mlxBackendStreamFallbackAndCancel() async throws {
        try await withTempDirAsync("rexplain-mlx-proc") { tempDir in
            func writeExecutable(_ name: String, script: String) throws -> URL {
                let url = tempDir.appendingPathComponent(name)
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                return url
            }

            _ = try writeExecutable("mlx_lm.generate", script: """
            #!/bin/sh
            echo "ValueError: model_type vision_model not supported" >&2
            exit 1
            """)
            _ = try writeExecutable("mlx_vlm.generate", script: """
            #!/bin/sh
            printf "==========\\n1. First step via VLM fallback.\\n==========\\nStats: ignored\\n"
            """)
            let slowCmd = try writeExecutable("slow_mlx.sh", script: """
            #!/bin/sh
            printf "==========\\n1. Partial chunk\\n"
            /bin/sleep 10
            """)

            let locator = MLXExecutableLocator(environment: ["PATH": tempDir.path], hubURL: tempDir)
            let backend = MLXBackend(model: "org/multimodal-model", runner: .auto, locator: locator)
            #expect(backend.displayBadge == "Local · multimodal-model")
            #expect(backend.supportsPrewarm == false)

            let engine = ExplainEngine(backend: backend)
            let prepCollector = EventCollector()
            await engine.prepare { prepCollector.append($0) }
            #expect(prepCollector.events.first?.type == "ready")
            #expect(prepCollector.events.first?.prewarmed == false)
            #expect(prepCollector.events.first?.modelLabel == "Local · multimodal-model")

            let explainCollector = EventCollector()
            await engine.explain(text: "Vision transformer", detail: .compact) {
                explainCollector.append($0)
            }
            let explainEvents = explainCollector.events
            let deltas = explainEvents.filter { $0.type == "delta" }.compactMap(\.text).joined()
            #expect(deltas == "1. First step via VLM fallback.\n")
            #expect(explainEvents.last?.type == "completed")
            #expect(!deltas.contains("Stats: ignored"))

            let slowEngine = ExplainEngine(backend: MLXBackend(model: "org/slow", runner: .mlxLM, customCommand: slowCmd.path, locator: locator))
            let cancelCollector = EventCollector()
            let task = Task {
                await slowEngine.explain(text: "Slow input", detail: .compact) {
                    cancelCollector.append($0)
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            await slowEngine.cancelActive()
            await task.value
            #expect(cancelCollector.events.contains { $0.type == "cancelled" })
        }
    }
}
