import Foundation

public enum ConfigSubcommand: Equatable, Sendable {
    case show(json: Bool, overrides: ConfigOverrides)
    case setFMF
    case setMLX(model: String, runner: MLXRunnerKind?, command: String?)
    case models(json: Bool, overrides: ConfigOverrides)
    case path
}

public enum CLICommand: Equatable, Sendable {
    case explain(ExplainOptions)
    case status(json: Bool, overrides: ConfigOverrides)
    case health(overrides: ConfigOverrides)
    case worker(outputPath: String?, idleTimeout: TimeInterval, overrides: ConfigOverrides)
    case view(ViewOptions)
    case config(ConfigSubcommand)
    case version
    case help

    public struct ExplainOptions: Equatable, Sendable {
        public var detail: DetailLevel
        public var text: String?
        public var filePath: String?
        public var deleteFile: Bool
        public var readStdin: Bool
        public var json: Bool
        public var styled: Bool
        public var overrides: ConfigOverrides
    }

    public struct ViewOptions: Equatable, Sendable {
        public var streamFile: String
        public var workerPID: Int32?
        public var detail: DetailLevel
        public var modelLabel: String
        public var cleanupDir: String?
    }

    private static let backendValueFlags: Set<String> = ["backend", "model", "mlx-runner", "mlx-command"]

    public static func parse(_ args: [String]) throws -> CLICommand {
        guard let rawCommand = args.first else {
            throw CLIParseError("Missing subcommand.")
        }
        let rest = Array(args.dropFirst())
        switch rawCommand {
        case "version", "--version", "-v":
            return .version
        case "help", "--help", "-h":
            return .help
        case "health":
            let flags = try parseFlags(rest, valueFlags: backendValueFlags, boolFlags: [])
            return .health(overrides: try parseConfigOverrides(from: flags.values))
        case "status":
            let (json, overrides) = try parseJSONAndOverrides(rest)
            return .status(json: json, overrides: overrides)
        case "worker":
            let flags = try parseFlags(rest, valueFlags: Set(["output", "idle-timeout"]).union(backendValueFlags), boolFlags: [])
            let timeout = flags.values["idle-timeout"].flatMap(Double.init) ?? 120.0
            return .worker(outputPath: flags.values["output"], idleTimeout: max(1.0, timeout), overrides: try parseConfigOverrides(from: flags.values))
        case "view":
            let flags = try parseFlags(rest, valueFlags: ["stream-file", "worker-pid", "detail", "label", "cleanup-dir"], boolFlags: [])
            guard let streamFile = flags.values["stream-file"], !streamFile.isEmpty else {
                throw CLIParseError("Missing --stream-file PATH for view.")
            }
            return .view(ViewOptions(
                streamFile: streamFile,
                workerPID: flags.values["worker-pid"].flatMap(Int32.init),
                detail: try parseDetail(flags.values["detail"]) ?? .compact,
                modelLabel: flags.values["label"].trimmedOrNil ?? "On-device",
                cleanupDir: flags.values["cleanup-dir"]
            ))
        case "config":
            return .config(try parseConfigSubcommand(rest))
        case "explain":
            let flags = try parseFlags(
                rest,
                valueFlags: Set(["detail", "text", "file"]).union(backendValueFlags),
                boolFlags: ["stdin", "delete-file", "json", "styled"]
            )
            return .explain(ExplainOptions(
                detail: try parseDetail(flags.values["detail"]) ?? .compact,
                text: flags.values["text"],
                filePath: flags.values["file"],
                deleteFile: flags.bools.contains("delete-file"),
                readStdin: flags.bools.contains("stdin"),
                json: flags.bools.contains("json"),
                styled: flags.bools.contains("styled"),
                overrides: try parseConfigOverrides(from: flags.values)
            ))
        default:
            throw CLIParseError("Unknown command '\(rawCommand)'.")
        }
    }

    private static func parseConfigSubcommand(_ args: [String]) throws -> ConfigSubcommand {
        guard let first = args.first else {
            return .show(json: false, overrides: ConfigOverrides())
        }
        if first.hasPrefix("--") {
            let (json, overrides) = try parseJSONAndOverrides(args)
            return .show(json: json, overrides: overrides)
        }
        let rest = Array(args.dropFirst())
        switch first {
        case "show":
            let (json, overrides) = try parseJSONAndOverrides(rest)
            return .show(json: json, overrides: overrides)
        case "models":
            let (json, overrides) = try parseJSONAndOverrides(rest)
            return .models(json: json, overrides: overrides)
        case "path":
            guard rest.isEmpty else { throw CLIParseError("Unexpected argument '\(rest[0])' for `config path`.") }
            return .path
        case "set-fmf":
            guard rest.isEmpty else { throw CLIParseError("Unexpected argument '\(rest[0])' for `config set-fmf`.") }
            return .setFMF
        case "set-mlx":
            let positionalModel = rest.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
            let remaining = positionalModel == nil ? rest : Array(rest.dropFirst())
            let flags = try parseFlags(remaining, valueFlags: ["model", "mlx-runner", "mlx-command"], boolFlags: [])
            guard let model = positionalModel.trimmedOrNil ?? flags.values["model"].trimmedOrNil else {
                throw CLIParseError("Missing model identifier for `config set-mlx` (pass <hf-repo-or-path>).")
            }
            return .setMLX(model: model, runner: try parseRunner(flags.values["mlx-runner"]), command: flags.values["mlx-command"].trimmedOrNil)
        default:
            throw CLIParseError("Unknown config subcommand '\(first)'.")
        }
    }

    private static func parseJSONAndOverrides(_ args: [String]) throws -> (Bool, ConfigOverrides) {
        let flags = try parseFlags(args, valueFlags: backendValueFlags, boolFlags: ["json"])
        return (flags.bools.contains("json"), try parseConfigOverrides(from: flags.values))
    }

    private struct ParsedFlags {
        var values: [String: String] = [:]
        var bools: Set<String> = []
    }

    private static func parseFlags(_ args: [String], valueFlags: Set<String>, boolFlags: Set<String>) throws -> ParsedFlags {
        var result = ParsedFlags()
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else {
                throw CLIParseError("Unexpected argument '\(arg)'.")
            }
            let name = String(arg.dropFirst(2))
            if boolFlags.contains(name) {
                result.bools.insert(name)
                i += 1
            } else if valueFlags.contains(name) {
                guard i + 1 < args.count else {
                    throw CLIParseError("Option '--\(name)' expects a value.")
                }
                result.values[name] = args[i + 1]
                i += 2
            } else {
                throw CLIParseError("Unknown option '--\(name)'.")
            }
        }
        return result
    }

    private static func parseConfigOverrides(from values: [String: String]) throws -> ConfigOverrides {
        var backend: ModelBackendKind?
        if let rawBackend = values["backend"] {
            guard let parsed = ModelBackendKind.parse(rawBackend) else {
                throw CLIParseError("Invalid backend '\(rawBackend)'. Expected fmf or mlx.")
            }
            backend = parsed
        }
        return ConfigOverrides(
            backend: backend,
            model: values["model"],
            mlxRunner: try parseRunner(values["mlx-runner"]),
            mlxCommand: values["mlx-command"]
        )
    }

    private static func parseRunner(_ raw: String?) throws -> MLXRunnerKind? {
        guard let raw else { return nil }
        guard let parsed = MLXRunnerKind.parse(raw) else {
            throw CLIParseError("Invalid MLX runner '\(raw)'. Expected auto, mlx_lm, or mlx_vlm.")
        }
        return parsed
    }

    private static func parseDetail(_ raw: String?) throws -> DetailLevel? {
        guard let raw else { return nil }
        guard let detail = DetailLevel.parse(raw) else {
            throw CLIParseError("Invalid detail level '\(raw)'. Expected compact, standard, or first-principles.")
        }
        return detail
    }
}

public struct CLIParseError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

public struct ConfigShowReport: Codable, Equatable, Sendable {
    public var backend: ModelBackendKind
    public var mlxModel: String?
    public var mlxRunner: MLXRunnerKind
    public var mlxCommand: String?
    public var firstRunHintShown: Bool
    public var displayBadge: String
    public var activeModel: String
    public var hasOverride: Bool
    public var configPath: String

    public init(config: RexplainConfig, hasOverride: Bool, configPath: String) {
        self.backend = config.backend
        self.mlxModel = config.mlxModel
        self.mlxRunner = config.mlxRunner
        self.mlxCommand = config.mlxCommand
        self.firstRunHintShown = config.firstRunHintShown
        self.displayBadge = config.displayBadge
        self.activeModel = config.activeModelDescription
        self.hasOverride = hasOverride
        self.configPath = configPath
    }

    enum CodingKeys: String, CodingKey {
        case backend
        case mlxModel = "mlx_model"
        case mlxRunner = "mlx_runner"
        case mlxCommand = "mlx_command"
        case firstRunHintShown = "first_run_hint_shown"
        case displayBadge = "display_badge"
        case activeModel = "active_model"
        case hasOverride = "has_override"
        case configPath = "config_path"
    }
}

public struct ConfigModelsReport: Codable, Equatable, Sendable {
    public var activeBackend: ModelBackendKind
    public var activeModel: String
    public var displayBadge: String
    public var configPath: String
    public var fmfAvailable: Bool
    public var fmfDetail: String
    public var mlxLMAvailable: Bool
    public var mlxVLMAvailable: Bool
    public var mlxLMPath: String?
    public var mlxVLMPath: String?
    public var cachedModels: [CachedMLXModel]

    enum CodingKeys: String, CodingKey {
        case activeBackend = "active_backend"
        case activeModel = "active_model"
        case displayBadge = "display_badge"
        case configPath = "config_path"
        case fmfAvailable = "fmf_available"
        case fmfDetail = "fmf_detail"
        case mlxLMAvailable = "mlx_lm_available"
        case mlxVLMAvailable = "mlx_vlm_available"
        case mlxLMPath = "mlx_lm_path"
        case mlxVLMPath = "mlx_vlm_path"
        case cachedModels = "cached_models"
    }
}

public enum RexplainCLI {
    public static func run(
        _ args: [String],
        configStore: ConfigStore = ConfigStore(),
        inspector: ModelAvailabilityInspector = ModelAvailabilityInspector(),
        locator: MLXExecutableLocator = MLXExecutableLocator(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Int32 {
        let command: CLICommand
        do {
            command = try CLICommand.parse(args)
        } catch {
            fputs("Rexplain: \(error.localizedDescription)\n", stderr)
            usage(to: stderr)
            return 2
        }

        switch command {
        case .version:
            print("Rexplain \(RexplainVersion.current)")
            return 0
        case .help:
            usage(to: stdout)
            return 0
        case .health(let overrides):
            guard let resolved = resolveOrPrintError(store: configStore, overrides: overrides, environment: environment) else { return 2 }
            let backend = BackendFactory.makeBackend(config: resolved.config, inspector: inspector, locator: locator)
            let status = backend.availabilityStatus()
            let suffix = resolved.config.backend == .fmf ? "" : " (\(backend.displayBadge))"
            print(status.available ? "available\(suffix)" : "unavailable: \(status.detailMessage)")
            return status.available ? 0 : 1
        case .status(let json, let overrides):
            guard let resolved = resolveOrPrintError(store: configStore, overrides: overrides, environment: environment) else { return 2 }
            let mlxEnv = locator.environmentStatus()
            let report = inspector.statusReport(config: resolved.config, configPath: configStore.displayPath, mlxStatus: mlxEnv)
            let activeStatus = BackendFactory.makeBackend(config: resolved.config, inspector: inspector, locator: locator).availabilityStatus()
            if json { return printJSON(report) }

            let fmfState = report.onDevice.available ? "available" : "unavailable (\(report.onDevice.reason?.rawValue ?? "unknown"))"
            print("active: \(report.displayBadge) (\(report.activeBackend.rawValue): \(report.activeModel))")
            print("config: \(report.configPath)")
            print("on-device (FMF): \(fmfState) — \(report.onDevice.detailMessage)")
            print("mlx-lm: \(mlxEnv.lmPath ?? "not found") | mlx-vlm: \(mlxEnv.vlmPath ?? "not found") | cached models: \(mlxEnv.cachedModels.count)")
            return activeStatus.available ? 0 : 1
        case .config(let subcommand):
            return runConfig(subcommand, store: configStore, inspector: inspector, locator: locator, environment: environment)
        case .worker(let outputPath, let idleTimeout, let overrides):
            guard let resolved = resolveOrPrintError(store: configStore, overrides: overrides, environment: environment) else { return 2 }
            let backend = BackendFactory.makeBackend(config: resolved.config, inspector: inspector, locator: locator)
            let engine = ExplainEngine(backend: backend) {
                configStore.consumeFirstRunHintIfNeeded(resolved: resolved.config, hasExplicitOverride: resolved.hasExplicitOverride)
            }
            return await WorkerLoop.run(engine: engine, outputPath: outputPath, idleTimeoutSeconds: idleTimeout)
        case .view(let opts):
            return StreamViewer.run(streamFile: opts.streamFile, workerPID: opts.workerPID, detail: opts.detail, modelLabel: opts.modelLabel, cleanupDir: opts.cleanupDir)
        case .explain(let opts):
            return await runExplain(opts, configStore: configStore, inspector: inspector, locator: locator, environment: environment)
        }
    }

    private static func resolveOrPrintError(
        store: ConfigStore,
        overrides: ConfigOverrides,
        environment: [String: String]
    ) -> (config: RexplainConfig, hasExplicitOverride: Bool)? {
        do {
            return try store.resolve(overrides: overrides, environment: environment)
        } catch {
            fputs("Rexplain: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private static func mutateConfig(store: ConfigStore, _ body: (inout RexplainConfig) -> String) -> Int32 {
        do {
            var current = try store.load()
            let confirmation = body(&current)
            current.firstRunHintShown = true
            try store.save(current)
            print(confirmation)
            return 0
        } catch {
            fputs("Rexplain: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func runConfig(
        _ subcommand: ConfigSubcommand,
        store: ConfigStore,
        inspector: ModelAvailabilityInspector,
        locator: MLXExecutableLocator,
        environment: [String: String]
    ) -> Int32 {
        switch subcommand {
        case .path:
            print(store.configURL.path)
            return 0
        case .setFMF:
            return mutateConfig(store: store) { config in
                config.backend = .fmf
                return "Default backend set to Apple On-device (FMF) in \(store.displayPath)."
            }
        case .setMLX(let model, let runner, let command):
            return mutateConfig(store: store) { config in
                config.backend = .mlx
                config.mlxModel = model
                if let runner { config.mlxRunner = runner }
                if let command { config.mlxCommand = command }
                return "Default backend set to Local MLX model '\(model)' in \(store.displayPath)."
            }
        case .show(let json, let overrides):
            guard let resolved = resolveOrPrintError(store: store, overrides: overrides, environment: environment) else { return 2 }
            let report = ConfigShowReport(config: resolved.config, hasOverride: resolved.hasExplicitOverride, configPath: store.displayPath)
            if json { return printJSON(report) }
            print("Backend: \(report.backend.rawValue) (\(report.displayBadge))")
            print("Model:   \(report.activeModel)")
            if report.backend == .mlx {
                print("Runner:  \(report.mlxRunner.rawValue)\(report.mlxCommand.map { " (command: \($0))" } ?? "")")
            }
            print("Config:  \(report.configPath)")
            return 0
        case .models(let json, let overrides):
            guard let resolved = resolveOrPrintError(store: store, overrides: overrides, environment: environment) else { return 2 }
            let fmf = inspector.status()
            let mlxEnv = locator.environmentStatus()
            let report = ConfigModelsReport(
                activeBackend: resolved.config.backend,
                activeModel: resolved.config.activeModelDescription,
                displayBadge: resolved.config.displayBadge,
                configPath: store.displayPath,
                fmfAvailable: fmf.available,
                fmfDetail: fmf.detailMessage,
                mlxLMAvailable: mlxEnv.lmAvailable,
                mlxVLMAvailable: mlxEnv.vlmAvailable,
                mlxLMPath: mlxEnv.lmPath,
                mlxVLMPath: mlxEnv.vlmPath,
                cachedModels: mlxEnv.cachedModels
            )
            if json { return printJSON(report) }
            print("Active: \(report.displayBadge) (\(report.activeBackend.rawValue): \(report.activeModel))")
            print("Apple Foundation Model (FMF): \(fmf.available ? "available" : "unavailable — \(fmf.detailMessage)")")
            print("MLX runners: mlx_lm=\(mlxEnv.lmPath ?? "missing"), mlx_vlm=\(mlxEnv.vlmPath ?? "missing")")
            if mlxEnv.cachedModels.isEmpty {
                print("Cached Hugging Face MLX models: none found in \(locator.hubURL.path)")
            } else {
                print("Cached Hugging Face models:")
                for model in mlxEnv.cachedModels {
                    let marker = (report.activeBackend == .mlx && report.activeModel == model.id) ? "*" : "-"
                    print("  \(marker) \(model.id) [suggested: \(model.suggestedRunner.rawValue)]")
                }
            }
            return 0
        }
    }

    private static func runExplain(
        _ opts: CLICommand.ExplainOptions,
        configStore: ConfigStore,
        inspector: ModelAvailabilityInspector,
        locator: MLXExecutableLocator,
        environment: [String: String]
    ) async -> Int32 {
        guard let resolved = resolveOrPrintError(store: configStore, overrides: opts.overrides, environment: environment) else {
            return 2
        }

        let inputText: String?
        do {
            inputText = try readInput(text: opts.text, filePath: opts.filePath, deleteFile: opts.deleteFile, readStdin: opts.readStdin)
        } catch {
            fputs("Rexplain: \(error.localizedDescription)\n", stderr)
            return 1
        }

        let backend = BackendFactory.makeBackend(config: resolved.config, inspector: inspector, locator: locator)
        let engine = ExplainEngine(backend: backend) {
            opts.json ? nil : configStore.consumeFirstRunHintIfNeeded(resolved: resolved.config, hasExplicitOverride: resolved.hasExplicitOverride)
        }

        if opts.styled && !opts.json {
            print(TerminalRenderer.headerString(detail: opts.detail, modelLabel: backend.displayBadge), terminator: "")
            fflush(stdout)
        }

        let box = RunOutcomeBox()
        await engine.explain(text: inputText, detail: opts.detail) { event in
            emitCLIEvent(event, json: opts.json, styled: opts.styled, box: box)
        }
        return box.exitCode
    }

    private static func readInput(text: String?, filePath: String?, deleteFile: Bool, readStdin: Bool) throws -> String? {
        if let text { return text }
        if let filePath {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            if deleteFile { try? FileManager.default.removeItem(atPath: filePath) }
            return content
        }
        if readStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return data.isEmpty ? nil : String(data: data, encoding: .utf8)
        }
        return nil
    }

    private static func printJSON<T: Encodable>(_ value: T) -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let out = String(data: data, encoding: .utf8) else { return 1 }
        print(out)
        return 0
    }

    private final class RunOutcomeBox: @unchecked Sendable {
        var exitCode: Int32 = 0
        var pendingHint: String?
        private let encoder = JSONEncoder()

        func encode(_ event: RexplainEvent) -> Data? {
            guard var data = try? encoder.encode(event) else { return nil }
            data.append(10)
            return data
        }
    }

    private static func emitCLIEvent(_ event: RexplainEvent, json: Bool, styled: Bool, box: RunOutcomeBox) {
        if json {
            if let line = box.encode(event) { FileHandle.standardOutput.write(line) }
            if event.type == "error" { box.exitCode = 1 }
            return
        }

        switch event.type {
        case "started":
            if let hint = event.hint, !hint.isEmpty { box.pendingHint = hint }
        case "delta":
            if let text = event.text {
                print(text, terminator: "")
                fflush(stdout)
            }
        case "replace":
            if let text = event.text {
                print("\n[updated]\n" + text, terminator: "")
                fflush(stdout)
            }
        case "completed":
            print("")
            if let hint = box.pendingHint, !hint.isEmpty {
                if styled { print("\n\u{001B}[2m\(hint)\u{001B}[0m") }
                else { fputs("\n\(hint)\n", stderr) }
            }
            fflush(stdout)
        case "error":
            fputs("Rexplain: \(event.error ?? "Unknown model error")\n", stderr)
            box.exitCode = 1
        default:
            break
        }
    }

    private static func usage(to stream: UnsafeMutablePointer<FILE>) {
        let text = """
        Rexplain \(RexplainVersion.current) — local technical explainer (Apple Foundation Models + MLX CLI)

        Usage:
          rexplain explain [--detail compact|standard|first-principles]
                           [--backend fmf|mlx] [--model MODEL]
                           [--mlx-runner auto|mlx_lm|mlx_vlm] [--mlx-command PATH]
                           (--text TEXT | --file PATH [--delete-file] | --stdin)
                           [--json] [--styled]
          rexplain config [show [--json]]
          rexplain config set-fmf
          rexplain config set-mlx <hf-repo-or-path> [--mlx-runner auto|mlx_lm|mlx_vlm] [--mlx-command PATH]
          rexplain config models [--json]
          rexplain config path
          rexplain status [--json] [--backend fmf|mlx] [--model MODEL]
          rexplain health [--backend fmf|mlx] [--model MODEL]
          rexplain worker [--output PATH] [--idle-timeout SECS]
                          [--backend fmf|mlx] [--model MODEL]
                          [--mlx-runner auto|mlx_lm|mlx_vlm] [--mlx-command PATH]
          rexplain view --stream-file PATH [--worker-pid PID] [--detail DETAIL]
                        [--label BADGE] [--cleanup-dir PATH]
          rexplain version

        """
        fputs(text, stream)
    }
}
