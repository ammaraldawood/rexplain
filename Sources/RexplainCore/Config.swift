import Foundation

extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    var trimmedOrNil: String? {
        self?.trimmedOrNil
    }
}

public enum ModelBackendKind: String, Codable, Equatable, Sendable {
    case fmf
    case mlx

    public static func parse(_ raw: String) -> ModelBackendKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fmf", "apple", "apple-fmf", "apple_fmf", "on-device", "on_device", "ondevice":
            return .fmf
        case "mlx", "local-mlx", "local_mlx", "mlx-lm", "mlx_lm", "mlx-vlm", "mlx_vlm":
            return .mlx
        default:
            return nil
        }
    }
}

public enum MLXRunnerKind: String, Codable, Equatable, Sendable {
    case auto
    case mlxLM = "mlx_lm"
    case mlxVLM = "mlx_vlm"

    public static func parse(_ raw: String) -> MLXRunnerKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto":
            return .auto
        case "mlx_lm", "mlx-lm", "mlxlm", "lm":
            return .mlxLM
        case "mlx_vlm", "mlx-vlm", "mlxvlm", "vlm":
            return .mlxVLM
        default:
            return nil
        }
    }
}

public struct RexplainConfig: Codable, Equatable, Sendable {
    public var backend: ModelBackendKind
    public var mlxModel: String?
    public var mlxRunner: MLXRunnerKind
    public var mlxCommand: String?
    public var firstRunHintShown: Bool

    public init(
        backend: ModelBackendKind = .fmf,
        mlxModel: String? = nil,
        mlxRunner: MLXRunnerKind = .auto,
        mlxCommand: String? = nil,
        firstRunHintShown: Bool = false
    ) {
        self.backend = backend
        self.mlxModel = mlxModel.trimmedOrNil
        self.mlxRunner = mlxRunner
        self.mlxCommand = mlxCommand.trimmedOrNil
        self.firstRunHintShown = firstRunHintShown
    }

    enum CodingKeys: String, CodingKey {
        case backend
        case mlxModel = "mlx_model"
        case mlxRunner = "mlx_runner"
        case mlxCommand = "mlx_command"
        case firstRunHintShown = "first_run_hint_shown"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBackend = try c.decodeIfPresent(ModelBackendKind.self, forKey: .backend)
        let decodedModel = (try c.decodeIfPresent(String.self, forKey: .mlxModel)).trimmedOrNil
        let decodedRunner = try c.decodeIfPresent(MLXRunnerKind.self, forKey: .mlxRunner) ?? .auto
        let decodedCommand = (try c.decodeIfPresent(String.self, forKey: .mlxCommand)).trimmedOrNil
        let decodedHint = try c.decodeIfPresent(Bool.self, forKey: .firstRunHintShown) ?? false

        self.backend = decodedBackend ?? (decodedModel != nil ? .mlx : .fmf)
        self.mlxModel = decodedModel
        self.mlxRunner = decodedRunner
        self.mlxCommand = decodedCommand
        self.firstRunHintShown = decodedHint
    }

    public var shortMLXModelName: String {
        guard let model = mlxModel.trimmedOrNil else { return "MLX" }
        let leaf = model.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").last.map(String.init) ?? ""
        guard !leaf.isEmpty else { return "MLX" }
        return leaf.count > 42 ? String(leaf.prefix(41)) + "…" : leaf
    }

    public var displayBadge: String {
        backend == .fmf ? "On-device" : "Local · \(shortMLXModelName)"
    }

    public var activeModelDescription: String {
        backend == .fmf ? "Apple Foundation Model" : (mlxModel ?? "(not configured)")
    }
}

public struct ConfigOverrides: Equatable, Sendable {
    public var backend: ModelBackendKind?
    public var model: String?
    public var mlxRunner: MLXRunnerKind?
    public var mlxCommand: String?

    public init(
        backend: ModelBackendKind? = nil,
        model: String? = nil,
        mlxRunner: MLXRunnerKind? = nil,
        mlxCommand: String? = nil
    ) {
        self.backend = backend
        self.model = model.trimmedOrNil
        self.mlxRunner = mlxRunner
        self.mlxCommand = mlxCommand.trimmedOrNil
    }

    public var isEmpty: Bool {
        backend == nil && model == nil && mlxRunner == nil && mlxCommand == nil
    }

    static func fromEnvironment(_ env: [String: String]) throws -> ConfigOverrides {
        var backend: ModelBackendKind?
        if let raw = env["REXPLAIN_BACKEND"].trimmedOrNil {
            guard let parsed = ModelBackendKind.parse(raw) else {
                throw ConfigError("Invalid REXPLAIN_BACKEND '\(raw)'. Expected fmf or mlx.")
            }
            backend = parsed
        }
        var runner: MLXRunnerKind?
        if let raw = env["REXPLAIN_MLX_RUNNER"].trimmedOrNil {
            guard let parsed = MLXRunnerKind.parse(raw) else {
                throw ConfigError("Invalid REXPLAIN_MLX_RUNNER '\(raw)'. Expected auto, mlx_lm, or mlx_vlm.")
            }
            runner = parsed
        }
        return ConfigOverrides(
            backend: backend,
            model: env["REXPLAIN_MODEL"],
            mlxRunner: runner,
            mlxCommand: env["REXPLAIN_MLX_COMMAND"]
        )
    }
}

public struct ConfigError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

public struct ConfigStore: Sendable {
    public let configURL: URL

    public init(
        configURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.configURL = configURL ?? Self.defaultConfigURL(environment: environment)
    }

    public static func defaultConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment["REXPLAIN_CONFIG_PATH"].trimmedOrNil {
            return URL(fileURLWithPath: expandTilde(explicit))
        }
        if let xdg = environment["XDG_CONFIG_HOME"].trimmedOrNil {
            return URL(fileURLWithPath: expandTilde(xdg), isDirectory: true)
                .appendingPathComponent("rexplain/config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rexplain/config.json")
    }

    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = configURL.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    public func load() throws -> RexplainConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return RexplainConfig()
        }
        let data = try Data(contentsOf: configURL)
        do {
            return try JSONDecoder().decode(RexplainConfig.self, from: data)
        } catch {
            throw ConfigError("Invalid Rexplain config JSON at \(displayPath): \(error.localizedDescription)")
        }
    }

    public func save(_ config: RexplainConfig) throws {
        let fm = FileManager.default
        let dir = configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(config)
        data.append(10)
        try data.write(to: configURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    public func resolve(
        overrides: ConfigOverrides = ConfigOverrides(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (config: RexplainConfig, hasExplicitOverride: Bool) {
        var config = try load()
        let envOverrides = try ConfigOverrides.fromEnvironment(environment)
        let appliedEnv = apply(envOverrides, to: &config)
        let appliedCLI = apply(overrides, to: &config)
        return (config, appliedEnv || appliedCLI)
    }

    public func consumeFirstRunHintIfNeeded(resolved: RexplainConfig, hasExplicitOverride: Bool) -> String? {
        guard !hasExplicitOverride, resolved.backend == .fmf, !resolved.firstRunHintShown else {
            return nil
        }
        var updated = (try? load()) ?? RexplainConfig()
        updated.firstRunHintShown = true
        try? save(updated)
        return "Tip: Using Apple On-device (FMF). Run 'rexplain config' or edit \(displayPath) to use any local MLX model."
    }

    private func apply(_ overrides: ConfigOverrides, to config: inout RexplainConfig) -> Bool {
        var applied = false
        let explicitBackend = overrides.backend != nil
        if let backend = overrides.backend {
            config.backend = backend
            applied = true
        }
        if let model = overrides.model.trimmedOrNil {
            if !explicitBackend && ModelBackendKind.parse(model) == .fmf {
                config.backend = .fmf
            } else {
                config.mlxModel = model
                if !explicitBackend {
                    config.backend = .mlx
                }
            }
            applied = true
        }
        if let runner = overrides.mlxRunner {
            config.mlxRunner = runner
            applied = true
        }
        if let cmd = overrides.mlxCommand.trimmedOrNil {
            config.mlxCommand = Self.expandTilde(cmd)
            applied = true
        }
        return applied
    }

    public static func expandTilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
    }
}

public struct CachedMLXModel: Codable, Equatable, Sendable {
    public var id: String
    public var shortName: String
    public var suggestedRunner: MLXRunnerKind
    public var isMLXCommunity: Bool
    public var snapshotPath: String
    public var contextSize: Int?

    public init(
        id: String,
        shortName: String,
        suggestedRunner: MLXRunnerKind,
        isMLXCommunity: Bool,
        snapshotPath: String,
        contextSize: Int? = nil
    ) {
        self.id = id
        self.shortName = shortName
        self.suggestedRunner = suggestedRunner
        self.isMLXCommunity = isMLXCommunity
        self.snapshotPath = snapshotPath
        self.contextSize = contextSize
    }

    enum CodingKeys: String, CodingKey {
        case id
        case shortName = "short_name"
        case suggestedRunner = "suggested_runner"
        case isMLXCommunity = "is_mlx_community"
        case snapshotPath = "snapshot_path"
        case contextSize = "context_size"
    }
}

public struct MLXModelMetadata: Equatable, Sendable {
    public var suggestedRunner: MLXRunnerKind
    public var contextSize: Int?
    public var configPath: String

    public init(suggestedRunner: MLXRunnerKind, contextSize: Int?, configPath: String) {
        self.suggestedRunner = suggestedRunner
        self.contextSize = contextSize
        self.configPath = configPath
    }
}

public enum MLXCacheDiscovery {
    public static func defaultHubURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let hubCache = environment["HUGGINGFACE_HUB_CACHE"].trimmedOrNil {
            return URL(fileURLWithPath: ConfigStore.expandTilde(hubCache), isDirectory: true)
        }
        if let hfHome = environment["HF_HOME"].trimmedOrNil {
            return URL(fileURLWithPath: ConfigStore.expandTilde(hfHome), isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    public static func discover(
        hubURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [CachedMLXModel] {
        let root = hubURL ?? defaultHubURL(environment: environment)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let models = entries.compactMap { entry -> CachedMLXModel? in
            let folderName = entry.lastPathComponent
            guard folderName.hasPrefix("models--"),
                  let modelId = decodeHFRepoId(folderName: folderName),
                  let snapshotDir = resolveSnapshotDir(modelRoot: entry, fileManager: fm) else {
                return nil
            }
            let configURL = snapshotDir.appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configURL.path) else { return nil }
            let metadata = parseModelConfig(at: configURL, modelNameHint: modelId)
            return CachedMLXModel(
                id: modelId,
                shortName: modelId.split(separator: "/").last.map(String.init) ?? modelId,
                suggestedRunner: metadata.suggestedRunner,
                isMLXCommunity: modelId.lowercased().hasPrefix("mlx-community/"),
                snapshotPath: snapshotDir.path,
                contextSize: metadata.contextSize
            )
        }

        return models.sorted {
            $0.isMLXCommunity != $1.isMLXCommunity
                ? ($0.isMLXCommunity && !$1.isMLXCommunity)
                : ($0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending)
        }
    }

    public static func inspectModel(
        _ model: String,
        hubURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MLXModelMetadata? {
        let fm = FileManager.default
        let directConfig = URL(fileURLWithPath: ConfigStore.expandTilde(model), isDirectory: true)
            .appendingPathComponent("config.json")
        if fm.fileExists(atPath: directConfig.path) {
            return parseModelConfig(at: directConfig, modelNameHint: model)
        }

        let hub = hubURL ?? defaultHubURL(environment: environment)
        let modelRoot = hub.appendingPathComponent("models--" + model.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        guard let snapshotDir = resolveSnapshotDir(modelRoot: modelRoot, fileManager: fm) else { return nil }
        let cachedConfig = snapshotDir.appendingPathComponent("config.json")
        return fm.fileExists(atPath: cachedConfig.path) ? parseModelConfig(at: cachedConfig, modelNameHint: model) : nil
    }

    public static func looksLikeVLMName(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return ["-vl-", "-vl", "_vl_", "_vl", "vlm", "vision", "pixtral", "paligemma", "llava", "gemma-4-e"]
            .contains { lower.contains($0) }
    }

    private static func decodeHFRepoId(folderName: String) -> String? {
        let body = String(folderName.dropFirst("models--".count))
        guard !body.isEmpty else { return nil }
        guard let sep = body.range(of: "--") else { return body }
        let org = String(body[..<sep.lowerBound])
        let repo = String(body[sep.upperBound...])
        return (!org.isEmpty && !repo.isEmpty) ? "\(org)/\(repo)" : nil
    }

    private static func resolveSnapshotDir(modelRoot: URL, fileManager fm: FileManager) -> URL? {
        let snapshotsDir = modelRoot.appendingPathComponent("snapshots", isDirectory: true)
        if let rev = (try? String(contentsOf: modelRoot.appendingPathComponent("refs/main"), encoding: .utf8)).trimmedOrNil {
            let candidate = snapshotsDir.appendingPathComponent(rev, isDirectory: true)
            if fm.fileExists(atPath: candidate.appendingPathComponent("config.json").path) {
                return candidate
            }
        }
        guard let candidates = try? fm.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return candidates
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .sorted {
                let lDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            }.first
    }

    private static func parseModelConfig(at url: URL, modelNameHint: String) -> MLXModelMetadata {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MLXModelMetadata(suggestedRunner: looksLikeVLMName(modelNameHint) ? .mlxVLM : .mlxLM, contextSize: nil, configPath: url.path)
        }
        let isMultimodal = json["vision_config"] != nil || json["audio_config"] != nil || looksLikeVLMName(modelNameHint)
        let textConfig = json["text_config"] as? [String: Any]
        let maxPos = (json["max_position_embeddings"] as? Int) ?? (textConfig?["max_position_embeddings"] as? Int)
        return MLXModelMetadata(suggestedRunner: isMultimodal ? .mlxVLM : .mlxLM, contextSize: maxPos, configPath: url.path)
    }
}
