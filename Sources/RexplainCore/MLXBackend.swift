import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum MLXConcreteRunner: String, Equatable, Sendable {
    case mlxLM = "mlx_lm"
    case mlxVLM = "mlx_vlm"
}

public enum MLXInvocationStyle: Equatable, Sendable {
    case pythonScript(pythonExecutable: String, pythonArgs: [String], runner: MLXConcreteRunner)
    case directCLI(executable: String, runnerHint: MLXConcreteRunner)

    public var runner: MLXConcreteRunner {
        switch self {
        case .pythonScript(_, _, let runner): return runner
        case .directCLI(_, let hint): return hint
        }
    }
}

public struct MLXEnvironmentStatus: Codable, Equatable, Sendable {
    public var lmAvailable: Bool
    public var vlmAvailable: Bool
    public var lmPath: String?
    public var vlmPath: String?
    public var cachedModels: [CachedMLXModel]

    public init(
        lmAvailable: Bool,
        vlmAvailable: Bool,
        lmPath: String? = nil,
        vlmPath: String? = nil,
        cachedModels: [CachedMLXModel] = []
    ) {
        self.lmAvailable = lmAvailable
        self.vlmAvailable = vlmAvailable
        self.lmPath = lmPath
        self.vlmPath = vlmPath
        self.cachedModels = cachedModels
    }

    enum CodingKeys: String, CodingKey {
        case lmAvailable = "lm_available"
        case vlmAvailable = "vlm_available"
        case lmPath = "lm_path"
        case vlmPath = "vlm_path"
        case cachedModels = "cached_models"
    }
}

public struct MLXExecutableLocator: Sendable {
    public let environment: [String: String]
    public let extraSearchDirs: [String]
    public let hubURL: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        extraSearchDirs: [String] = [],
        hubURL: URL? = nil
    ) {
        self.environment = environment
        self.extraSearchDirs = extraSearchDirs
        self.hubURL = hubURL ?? MLXCacheDiscovery.defaultHubURL(environment: environment)
    }

    public func searchDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let envPathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let standardDirs = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.pyenv/shims",
            "\(home)/miniforge3/bin",
            "\(home)/miniconda3/bin",
            "/opt/miniconda3/bin",
            "\(home)/.local/share/uv/tools/mlx-lm/bin",
            "\(home)/.local/share/uv/tools/mlx-vlm/bin",
        ]

        var seen = Set<String>()
        return (envPathDirs + extraSearchDirs + standardDirs).compactMap { raw in
            let expanded = ConfigStore.expandTilde(raw)
            return (!expanded.isEmpty && seen.insert(expanded).inserted) ? expanded : nil
        }
    }

    public func findExecutable(named candidates: [String]) -> String? {
        let fm = FileManager.default
        let dirs = searchDirectories()
        for name in candidates {
            for dir in dirs {
                let candidatePath = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name).path
                if fm.isExecutableFile(atPath: candidatePath) {
                    return candidatePath
                }
            }
        }
        return nil
    }

    public func resolveRunner(_ runner: MLXConcreteRunner) -> String? {
        switch runner {
        case .mlxLM: return findExecutable(named: ["mlx_lm.generate", "mlx_lm"])
        case .mlxVLM: return findExecutable(named: ["mlx_vlm.generate", "mlx_vlm"])
        }
    }

    public func resolveCustomCommand(_ rawCommand: String) -> String? {
        guard let cleaned = rawCommand.trimmedOrNil else { return nil }
        let expanded = ConfigStore.expandTilde(cleaned)
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        return findExecutable(named: [expanded])
    }

    public func environmentStatus() -> MLXEnvironmentStatus {
        let lm = resolveRunner(.mlxLM)
        let vlm = resolveRunner(.mlxVLM)
        return MLXEnvironmentStatus(
            lmAvailable: lm != nil,
            vlmAvailable: vlm != nil,
            lmPath: lm,
            vlmPath: vlm,
            cachedModels: MLXCacheDiscovery.discover(hubURL: hubURL, environment: environment)
        )
    }

    public func parsePythonShebang(at executablePath: String) -> (executable: String, prefixArgs: [String])? {
        guard let fh = FileHandle(forReadingAtPath: executablePath) else { return nil }
        defer { try? fh.close() }
        let chunk = fh.readData(ofLength: 512)
        guard !chunk.isEmpty else { return nil }
        let lineData = chunk.firstIndex(of: 10).map { chunk.prefix(upTo: $0) } ?? chunk
        guard let stripped = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n \t")),
              stripped.hasPrefix("#!") else {
            return nil
        }
        let body = String(stripped.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }

        // Handle direct interpreter paths that may contain spaces before tokenizing flags.
        if FileManager.default.isExecutableFile(atPath: body),
           URL(fileURLWithPath: body).lastPathComponent.lowercased().hasPrefix("python") {
            return (body, [])
        }

        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first else { return nil }
        let firstBase = URL(fileURLWithPath: first).lastPathComponent.lowercased()

        if firstBase == "env" {
            var idx = 1
            while idx < tokens.count && tokens[idx].hasPrefix("-") { idx += 1 }
            guard idx < tokens.count,
                  URL(fileURLWithPath: tokens[idx]).lastPathComponent.lowercased().hasPrefix("python") else {
                return nil
            }
            return (first, Array(tokens[idx...]))
        }

        return firstBase.hasPrefix("python") ? (first, Array(tokens.dropFirst())) : nil
    }
}

private final class BoundedDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let maxBytes: Int

    init(maxBytes: Int = 16_384) {
        self.maxBytes = maxBytes
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        if buffer.count > maxBytes {
            buffer.removeFirst(buffer.count - maxBytes)
        }
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        let copy = buffer
        lock.unlock()
        return String(data: copy, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class ProcessControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func register(_ proc: Process) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { process = proc }
        lock.unlock()
        if alreadyCancelled { proc.terminate() }
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let proc = process
        process = nil
        lock.unlock()
        proc?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        let flag = cancelled
        lock.unlock()
        return flag
    }
}

private struct CLIBannerParser {
    private enum State { case initial, insideBody, afterClosingBanner, plainUnframed }

    private var state: State = .initial
    private var sawFirstLine = false
    private var buffer = Data()

    mutating func push(_ chunk: Data, onDelta: (String) -> Void) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 10) {
            let lineData = Data(buffer.prefix(through: nl))
            buffer.removeSubrange(...nl)
            emitCompleteLine(lineData, onDelta: onDelta)
        }
        if state == .plainUnframed && !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
            buffer.removeAll()
            onDelta(text)
        }
    }

    mutating func flush(onDelta: (String) -> Void) {
        guard !buffer.isEmpty else { return }
        if state != .afterClosingBanner {
            emitCompleteLine(buffer, onDelta: onDelta)
        }
        buffer.removeAll()
    }

    private mutating func emitCompleteLine(_ data: Data, onDelta: (String) -> Void) {
        guard let line = String(data: data, encoding: .utf8) else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        switch state {
        case .initial:
            if trimmed == "==========" {
                state = .insideBody
                sawFirstLine = true
                return
            }
            if !sawFirstLine && trimmed.hasPrefix("Calling `python -m") {
                sawFirstLine = true
                return
            }
            sawFirstLine = true
            state = .plainUnframed
            onDelta(line)
        case .insideBody:
            if trimmed == "==========" {
                state = .afterClosingBanner
                return
            }
            onDelta(line)
        case .afterClosingBanner:
            return
        case .plainUnframed:
            onDelta(line)
        }
    }
}

private final class MLXSessionHandle: ModelSessionHandle, @unchecked Sendable {
    let contextSize: Int
    private let model: String
    private let invocations: [MLXInvocationStyle]
    private let baseEnvironment: [String: String]

    init(
        model: String,
        invocations: [MLXInvocationStyle],
        contextSize: Int,
        environment: [String: String]
    ) {
        self.model = model
        self.invocations = invocations
        self.contextSize = contextSize
        self.baseEnvironment = environment
    }

    var isResponding: Bool { false }
    func prewarm(promptPrefix: String?) async {}
    func estimateInputTokens(for prompt: String) async -> Int? { nil }

    func streamResponse(to prompt: String, maxResponseTokens: Int) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        let model = self.model
        let invocations = self.invocations
        let baseEnvironment = self.baseEnvironment

        return AsyncThrowingStream { continuation in
            let control = ProcessControlBox()
            let thread = Thread {
                do {
                    guard !invocations.isEmpty else {
                        throw EngineFailure(code: .mlxUnavailable, message: "No local MLX runner (`mlx_lm` or `mlx_vlm`) is installed or executable.")
                    }

                    var lastFailure: EngineFailure?
                    for (index, invocation) in invocations.enumerated() {
                        if control.isCancelled { throw CancellationError() }
                        var yieldedAnyToken = false
                        do {
                            try Self.runSingleInvocation(
                                invocation: invocation,
                                model: model,
                                prompt: prompt,
                                maxTokens: maxResponseTokens,
                                baseEnvironment: baseEnvironment,
                                control: control,
                                onDelta: { delta in
                                    guard !delta.isEmpty else { return }
                                    yieldedAnyToken = true
                                    continuation.yield(.delta(delta))
                                }
                            )
                            continuation.finish()
                            return
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let failure as EngineFailure {
                            lastFailure = failure
                            if yieldedAnyToken || index + 1 >= invocations.count || control.isCancelled {
                                throw failure
                            }
                        }
                    }

                    if let lastFailure { throw lastFailure }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.name = "rexplain.mlx.stream"
            continuation.onTermination = { @Sendable _ in control.cancel() }
            thread.start()
        }
    }

    private static func runSingleInvocation(
        invocation: MLXInvocationStyle,
        model: String,
        prompt: String,
        maxTokens: Int,
        baseEnvironment: [String: String],
        control: ProcessControlBox,
        onDelta: (String) -> Void
    ) throws {
        let process = Process()
        var env = baseEnvironment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        let stdinPayload: Data?
        let isJSONLines: Bool

        switch invocation {
        case .pythonScript(let pyExe, let pyArgs, let runner):
            process.executableURL = URL(fileURLWithPath: pyExe)
            process.arguments = pyArgs + ["-u", "-c", pythonRunnerScript]
            stdinPayload = try? JSONSerialization.data(withJSONObject: [
                "runner": runner.rawValue,
                "model": model,
                "system": PromptTemplates.systemInstructions,
                "prompt": prompt,
                "max_tokens": maxTokens,
                "temp": MLXBackend.defaultTemperature,
                "top_p": MLXBackend.defaultTopP,
                "min_p": MLXBackend.defaultMinP,
                "repetition_penalty": MLXBackend.defaultRepetitionPenalty,
                "repetition_context_size": MLXBackend.defaultRepetitionContextSize,
            ])
            stdinPipe = Pipe()
            process.standardInput = stdinPipe
            isJSONLines = true

        case .directCLI(let executable, let runnerHint):
            process.executableURL = URL(fileURLWithPath: executable)
            var args = ["--model", model]
            switch runnerHint {
            case .mlxLM:
                args += [
                    "--system-prompt", PromptTemplates.systemInstructions,
                    "--prompt", "-",
                    "--max-tokens", String(maxTokens),
                    "--temp", String(MLXBackend.defaultTemperature),
                    "--top-p", String(MLXBackend.defaultTopP),
                    "--min-p", String(MLXBackend.defaultMinP),
                    "--verbose", "True",
                ]
                stdinPayload = prompt.data(using: .utf8)
                stdinPipe = Pipe()
                process.standardInput = stdinPipe
            case .mlxVLM:
                args += [
                    "--system", PromptTemplates.systemInstructions,
                    "--prompt", prompt,
                    "--max-tokens", String(maxTokens),
                    "--temp", String(MLXBackend.defaultTemperature),
                    "--top-p", String(MLXBackend.defaultTopP),
                    "--repetition-penalty", String(MLXBackend.defaultRepetitionPenalty),
                    "--verbose",
                ]
                stdinPayload = nil
                stdinPipe = nil
                process.standardInput = FileHandle.nullDevice
            }
            process.arguments = args
            isJSONLines = false
        }

        let stderrAccumulator = BoundedDataAccumulator()
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { stderrAccumulator.append(data) }
        }

        control.register(process)
        defer {
            control.clear()
            stderrHandle.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrHandle.close()
        }

        do {
            try process.run()
        } catch {
            throw EngineFailure(code: .mlxUnavailable, message: "Could not launch MLX process: \(error.localizedDescription)")
        }

        if control.isCancelled {
            process.terminate()
            throw CancellationError()
        }

        if let stdinPipe {
            if let stdinPayload, !stdinPayload.isEmpty {
                stdinPipe.fileHandleForWriting.write(stdinPayload)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        streamStdoutFD(stdoutPipe.fileHandleForReading.fileDescriptor, isJSONLines: isJSONLines, control: control, onDelta: onDelta)

        if control.isCancelled {
            if process.isRunning { process.terminate() }
            throw CancellationError()
        }

        process.waitUntilExit()
        stderrHandle.readabilityHandler = nil
        stderrAccumulator.append(stderrHandle.readDataToEndOfFile())

        if process.terminationStatus != 0 {
            throw EngineFailure(code: .internalError, message: summarizeErrorText(stderrAccumulator.text(), exitCode: process.terminationStatus, runner: invocation.runner))
        }
    }

    private static func streamStdoutFD(_ fd: Int32, isJSONLines: Bool, control: ProcessControlBox, onDelta: (String) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var lineBuffer = Data()
        var bannerParser = CLIBannerParser()

        while !control.isCancelled {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let pollResult = Darwin.poll(&pfd, 1, 100)
            if pollResult < 0 {
                if errno == EINTR { continue }
                break
            }
            if pollResult == 0 { continue }

            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }

            let chunk = Data(buffer[..<count])
            if isJSONLines {
                lineBuffer.append(chunk)
                while let nl = lineBuffer.firstIndex(of: 10) {
                    emitJSONDeltaLine(Data(lineBuffer.prefix(upTo: nl)), onDelta: onDelta)
                    lineBuffer.removeSubrange(...nl)
                }
            } else {
                bannerParser.push(chunk, onDelta: onDelta)
            }
        }

        guard !control.isCancelled else { return }
        if isJSONLines {
            if !lineBuffer.isEmpty { emitJSONDeltaLine(lineBuffer, onDelta: onDelta) }
        } else {
            bannerParser.flush(onDelta: onDelta)
        }
    }

    private static func emitJSONDeltaLine(_ lineData: Data, onDelta: (String) -> Void) {
        guard !lineData.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let delta = obj["delta"] as? String, !delta.isEmpty else {
            return
        }
        onDelta(delta)
    }

    private static func summarizeErrorText(_ raw: String, exitCode: Int32, runner: MLXConcreteRunner) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.isEmpty {
            return "MLX (\(runner.rawValue)) exited with status \(exitCode)."
        }
        return "MLX (\(runner.rawValue)) failed (exit \(exitCode)):\n\(lines.suffix(6).joined(separator: "\n"))"
    }

    private static let pythonRunnerScript = #"""
    import inspect, json, sys

    p = json.loads(sys.stdin.read())
    runner, model_id, sys_prompt, user_prompt = p["runner"], p["model"], p["system"], p["prompt"]
    max_tokens, temp, top_p, min_p = int(p["max_tokens"]), float(p["temp"]), float(p["top_p"]), float(p["min_p"])
    rep_penalty, rep_ctx = float(p["repetition_penalty"]), int(p["repetition_context_size"])
    messages = [{"role": "system", "content": sys_prompt}, {"role": "user", "content": user_prompt}]
    merged = f"{sys_prompt}\n\n{user_prompt}"

    def emit(text):
        if text:
            sys.stdout.write(json.dumps({"delta": text}, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    if runner == "mlx_lm":
        from mlx_lm import load, stream_generate
        from mlx_lm.sample_utils import make_logits_processors, make_sampler

        model, tok = load(model_id)
        if getattr(tok, "has_chat_template", False) or getattr(tok, "chat_template", None):
            try:
                prompt_text = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
            except Exception:
                prompt_text = tok.apply_chat_template([{"role": "user", "content": merged}], tokenize=False, add_generation_prompt=True)
        else:
            prompt_text = merged

        sampler = make_sampler(temp=temp, top_p=top_p, min_p=min_p)
        logits_processors = make_logits_processors(repetition_penalty=rep_penalty, repetition_context_size=rep_ctx)
        for r in stream_generate(model, tok, prompt_text, max_tokens=max_tokens, sampler=sampler, logits_processors=logits_processors):
            emit(getattr(r, "text", None))
    elif runner == "mlx_vlm":
        import mlx_vlm
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import load_config

        model, proc = mlx_vlm.load(model_id)
        cfg = load_config(model_id)
        try:
            prompt_text = apply_chat_template(proc, cfg, messages, num_images=0)
        except Exception:
            try:
                prompt_text = apply_chat_template(proc, cfg, merged, num_images=0)
            except Exception:
                prompt_text = merged

        stream_fn = getattr(mlx_vlm, "stream_generate", None)
        gen_fn = stream_fn or mlx_vlm.generate
        params = inspect.signature(gen_fn).parameters
        kw = {}
        for k, v in [("max_tokens", max_tokens), ("top_p", top_p), ("repetition_penalty", rep_penalty), ("repetition_context_size", rep_ctx), ("verbose", False)]:
            if k in params: kw[k] = v
        if "temp" in params: kw["temp"] = temp
        elif "temperature" in params: kw["temperature"] = temp

        if stream_fn is not None:
            for c in stream_fn(model, proc, prompt_text, **kw):
                emit(getattr(c, "text", c if isinstance(c, str) else ""))
        else:
            res = mlx_vlm.generate(model, proc, prompt_text, **kw)
            emit(getattr(res, "text", res if isinstance(res, str) else str(res)))
    else:
        raise ValueError(f"Unsupported MLX runner: {runner}")
    """#
}

public struct MLXBackend: LanguageModelBackend {
    public static let maximumSelectionCharactersLimit = 32_000
    public static let defaultContextSize = 16_384
    public static let defaultTemperature = 0.45
    public static let defaultTopP = 0.9
    public static let defaultMinP = 0.05
    public static let defaultRepetitionPenalty = 1.12
    public static let defaultRepetitionContextSize = 512

    public let model: String
    public let runner: MLXRunnerKind
    public let customCommand: String?
    public let locator: MLXExecutableLocator

    public let backendKind: ModelBackendKind = .mlx
    public let maximumSelectionCharacters: Int = MLXBackend.maximumSelectionCharactersLimit
    public let supportsPrewarm: Bool = false

    public var displayBadge: String { RexplainConfig(backend: .mlx, mlxModel: model).displayBadge }
    public var activeModelName: String { model.trimmedOrNil ?? "(not configured)" }

    public init(
        model: String,
        runner: MLXRunnerKind = .auto,
        customCommand: String? = nil,
        locator: MLXExecutableLocator = MLXExecutableLocator()
    ) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runner = runner
        self.customCommand = customCommand.trimmedOrNil
        self.locator = locator
    }

    public func resolvedContextSize() -> Int {
        guard !model.isEmpty,
              let maxPos = MLXCacheDiscovery.inspectModel(model, hubURL: locator.hubURL, environment: locator.environment)?.contextSize else {
            return Self.defaultContextSize
        }
        return min(32_768, max(4_096, maxPos))
    }

    public func resolveRunnerOrder() -> [MLXInvocationStyle] {
        guard !model.isEmpty else { return [] }

        if let customCommand {
            guard let resolved = locator.resolveCustomCommand(customCommand) else { return [] }
            let base = URL(fileURLWithPath: resolved).lastPathComponent.lowercased()
            let runnerHint: MLXConcreteRunner = switch runner {
            case .mlxLM: .mlxLM
            case .mlxVLM: .mlxVLM
            case .auto:
                base.hasPrefix("mlx_vlm") ? .mlxVLM : (base.hasPrefix("mlx_lm") ? .mlxLM : preferredConcreteRunner())
            }
            let allowPythonInline = base.hasPrefix("mlx_lm") || base.hasPrefix("mlx_vlm")
            return [makeInvocation(for: runnerHint, path: resolved, allowPythonInline: allowPythonInline)].compactMap { $0 }
        }

        let lmPath = locator.resolveRunner(.mlxLM)
        let vlmPath = locator.resolveRunner(.mlxVLM)

        switch runner {
        case .mlxLM:
            return [makeInvocation(for: .mlxLM, path: lmPath)].compactMap { $0 }
        case .mlxVLM:
            return [makeInvocation(for: .mlxVLM, path: vlmPath)].compactMap { $0 }
        case .auto:
            let primaryKind = preferredConcreteRunner()
            let secondaryKind: MLXConcreteRunner = primaryKind == .mlxVLM ? .mlxLM : .mlxVLM
            let paths: [MLXConcreteRunner: String?] = [.mlxLM: lmPath, .mlxVLM: vlmPath]
            return [primaryKind, secondaryKind].compactMap { kind in
                makeInvocation(for: kind, path: paths[kind] ?? nil)
            }
        }
    }

    public func availabilityStatus() -> LocalModelStatus {
        let ctx = resolvedContextSize()
        if model.isEmpty {
            return LocalModelStatus(
                available: false,
                reason: .invalidConfig,
                detailMessage: "No MLX model configured. Run `rexplain config set-mlx <hf-repo-or-path>` or switch back with `rexplain config set-fmf`.",
                contextSize: ctx
            )
        }
        if looksLikeLocalPath(model), !FileManager.default.fileExists(atPath: ConfigStore.expandTilde(model)) {
            return LocalModelStatus(available: false, reason: .invalidConfig, detailMessage: "Local MLX model path not found: \(model)", contextSize: ctx)
        }
        if let customCommand, locator.resolveCustomCommand(customCommand) == nil {
            return LocalModelStatus(available: false, reason: .mlxUnavailable, detailMessage: "Configured mlx_command '\(customCommand)' was not found or is not executable.", contextSize: ctx)
        }
        guard !resolveRunnerOrder().isEmpty else {
            let installHint = switch runner {
            case .mlxLM: "Install mlx-lm (`uv tool install mlx-lm` or `pipx install mlx-lm`)."
            case .mlxVLM: "Install mlx-vlm (`uv tool install mlx-vlm` or `pipx install mlx-vlm`)."
            case .auto: "Install mlx-lm (`uv tool install mlx-lm`) and/or mlx-vlm (`uv tool install mlx-vlm`)."
            }
            return LocalModelStatus(available: false, reason: .mlxUnavailable, detailMessage: "MLX runner unavailable for '\(model)'. \(installHint)", contextSize: ctx)
        }
        return LocalModelStatus(available: true, detailMessage: "Local MLX model configured: \(model) (runner: \(runner.rawValue)).", contextSize: ctx)
    }

    public func makeSession(instructions: String) throws -> any ModelSessionHandle {
        let status = availabilityStatus()
        guard status.available else {
            let code: RexplainErrorCode = status.reason == .invalidConfig ? .invalidConfig : .mlxUnavailable
            throw EngineFailure(code: code, message: status.detailMessage)
        }
        return MLXSessionHandle(model: model, invocations: resolveRunnerOrder(), contextSize: status.contextSize, environment: locator.environment)
    }

    private func preferredConcreteRunner() -> MLXConcreteRunner {
        if let meta = MLXCacheDiscovery.inspectModel(model, hubURL: locator.hubURL, environment: locator.environment) {
            return meta.suggestedRunner == .mlxVLM ? .mlxVLM : .mlxLM
        }
        return MLXCacheDiscovery.looksLikeVLMName(model) ? .mlxVLM : .mlxLM
    }

    private func makeInvocation(for kind: MLXConcreteRunner, path: String?, allowPythonInline: Bool = true) -> MLXInvocationStyle? {
        guard let path else { return nil }
        if allowPythonInline, let shebang = locator.parsePythonShebang(at: path) {
            return .pythonScript(pythonExecutable: shebang.executable, pythonArgs: shebang.prefixArgs, runner: kind)
        }
        return .directCLI(executable: path, runnerHint: kind)
    }

    private func looksLikeLocalPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("~/")
    }
}
