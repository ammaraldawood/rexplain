import Foundation
import Testing
@testable import RexplainCore

@Suite("CLI Parsing & Input")
struct CLITests {
    @Test("Parses explain with detail, text, and backend overrides")
    func parseExplainText() throws {
        let cmd = try CLICommand.parse([
            "explain", "--detail", "first-principles",
            "--backend", "mlx", "--model", "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            "--mlx-runner", "mlx_vlm", "--mlx-command", "/opt/bin/custom_mlx",
            "--text", "A -> B", "--json", "--styled"
        ])
        guard case .explain(let opts) = cmd else {
            Issue.record("Expected explain command")
            return
        }
        #expect(opts.detail == .firstPrinciples)
        #expect(opts.text == "A -> B")
        #expect(opts.json == true)
        #expect(opts.styled == true)
        #expect(opts.overrides.backend == .mlx)
        #expect(opts.overrides.model == "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        #expect(opts.overrides.mlxRunner == .mlxVLM)
        #expect(opts.overrides.mlxCommand == "/opt/bin/custom_mlx")
    }

    @Test("Defaults to Compact effort and empty overrides")
    func defaults() throws {
        let cmd = try CLICommand.parse(["explain", "--stdin"])
        guard case .explain(let opts) = cmd else {
            Issue.record("Expected explain command")
            return
        }
        #expect(opts.detail == .compact)
        #expect(opts.readStdin == true)
        #expect(opts.overrides.isEmpty)
    }

    @Test("Parses config subcommands cleanly")
    func parseConfigSubcommands() throws {
        #expect(try CLICommand.parse(["config"]) == .config(.show(json: false, overrides: ConfigOverrides())))
        #expect(try CLICommand.parse(["config", "show", "--json"]) == .config(.show(json: true, overrides: ConfigOverrides())))
        #expect(try CLICommand.parse(["config", "path"]) == .config(.path))
        #expect(try CLICommand.parse(["config", "set-fmf"]) == .config(.setFMF))
        #expect(try CLICommand.parse(["config", "models", "--json"]) == .config(.models(json: true, overrides: ConfigOverrides())))

        let setMLX = try CLICommand.parse([
            "config", "set-mlx", "mlx-community/Qwen2.5-0.5B-Instruct-4bit", "--mlx-runner", "mlx_lm"
        ])
        #expect(setMLX == .config(.setMLX(model: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", runner: .mlxLM, command: nil)))
    }

    @Test("Rejects removed context/metadata options, invalid options, and removed subcommands")
    func rejectsInvalidArguments() {
        for removedFlag in [["--context", "x"], ["--source", "nvim"], ["--filetype", "rust"]] {
            #expect(throws: CLIParseError.self) {
                _ = try CLICommand.parse(["explain", "--text", "hi"] + removedFlag)
            }
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["explain", "--mode", "deep", "--text", "hi"])
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["explain", "--backend", "cloud", "--text", "hi"])
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["explain", "--mlx-runner", "ollama", "--text", "hi"])
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["explain", "--detail", "essay", "--text", "hi"])
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["config", "set-mlx"])
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["follow-up", "--text", "why"])
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["reset", "--all"])
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["about-modes"])
        }
        #expect(throws: CLIParseError.self) {
            _ = try CLICommand.parse(["service"])
        }
    }

    @Test("Parses worker, view (with --label), status, health")
    func parseSubcommands() throws {
        let worker = try CLICommand.parse([
            "worker", "--output", "/tmp/out.jsonl", "--idle-timeout", "30",
            "--backend", "mlx", "--model", "local/model"
        ])
        #expect(worker == .worker(
            outputPath: "/tmp/out.jsonl",
            idleTimeout: 30,
            overrides: ConfigOverrides(backend: .mlx, model: "local/model")
        ))

        let view = try CLICommand.parse([
            "view", "--stream-file", "/tmp/s.jsonl", "--worker-pid", "4242",
            "--detail", "standard", "--label", "Local · Qwen", "--cleanup-dir", "/tmp/dir"
        ])
        guard case .view(let v) = view else {
            Issue.record("Expected view command")
            return
        }
        #expect(v.streamFile == "/tmp/s.jsonl")
        #expect(v.workerPID == 4242)
        #expect(v.detail == .standard)
        #expect(v.modelLabel == "Local · Qwen")
        #expect(v.cleanupDir == "/tmp/dir")

        #expect(try CLICommand.parse(["status", "--json"]) == .status(json: true, overrides: ConfigOverrides()))
        #expect(try CLICommand.parse(["health"]) == .health(overrides: ConfigOverrides()))
    }

    @Test("Explain --file --delete-file deletes temporary file after reading")
    func explainFileDelete() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("rexplain-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tmp = tempDir.appendingPathComponent("selection.txt")
        let cfg = tempDir.appendingPathComponent("config.json")
        try "   ".write(to: tmp, atomically: true, encoding: .utf8)

        let code = await RexplainCLI.run(
            ["explain", "--file", tmp.path, "--delete-file"],
            configStore: ConfigStore(configURL: cfg)
        )
        #expect(code == 1)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }
}
