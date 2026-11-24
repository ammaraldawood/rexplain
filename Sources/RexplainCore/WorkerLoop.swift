import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum WorkerLoop {
    public static func run(
        engine: ExplainEngine,
        outputPath: String? = nil,
        idleTimeoutSeconds: TimeInterval = 120
    ) async -> Int32 {
        let emitter = EventEmitter(outputPath: outputPath)
        let decoder = JSONDecoder()

        let activeSignalSources = installSignalHandlers(engine: engine, emitter: emitter)
        defer { activeSignalSources.forEach { $0.cancel() } }

        var iterator = makeStdinLineStream().makeAsyncIterator()
        var currentTask: Task<Void, Never>?
        var lastActivity = Date()

        func stopActive() async {
            await engine.cancelActive()
            currentTask?.cancel()
            await currentTask?.value
            currentTask = nil
        }

        while true {
            let outcome = await readNextCommandOrTaskFinish(
                iterator: &iterator,
                currentTask: currentTask,
                idleDeadline: lastActivity.addingTimeInterval(idleTimeoutSeconds)
            )

            switch outcome {
            case .taskCompleted:
                return 0
            case .timedOut:
                await stopActive()
                return 0
            case .eof:
                await currentTask?.value
                return 0
            case .line(let line):
                lastActivity = Date()
                guard let trimmed = line.trimmedOrNil else { continue }
                guard let data = trimmed.data(using: .utf8),
                      let command = try? decoder.decode(WorkerCommand.self, from: data) else {
                    emitter.emit(.message("error", error: "Invalid JSONL worker command.", errorCode: .invalidRequest))
                    continue
                }

                switch command.cmd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "prepare":
                    await engine.prepare { emitter.emit($0) }
                case "explain":
                    let detail = command.detail ?? .compact
                    await currentTask?.value
                    currentTask = Task {
                        await engine.explain(text: command.text, detail: detail) { emitter.emit($0) }
                    }
                case "cancel":
                    await stopActive()
                case "close":
                    await stopActive()
                    return 0
                default:
                    emitter.emit(.message("error", error: "Unknown worker command '\(command.cmd)'.", errorCode: .invalidRequest))
                }
            }
        }
    }

    private enum LoopPollOutcome {
        case line(String), eof, timedOut, taskCompleted
    }

    private final class EventEmitter: @unchecked Sendable {
        private let lock = NSLock()
        private let encoder = JSONEncoder()
        private let fileHandle: FileHandle?

        init(outputPath: String?) {
            guard let path = outputPath.trimmedOrNil else {
                self.fileHandle = nil
                return
            }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            self.fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? self.fileHandle?.seekToEnd()
        }

        deinit {
            try? fileHandle?.close()
        }

        func emit(_ event: RexplainEvent) {
            guard var data = try? encoder.encode(event) else { return }
            data.append(10)
            lock.lock()
            defer { lock.unlock() }
            FileHandle.standardOutput.write(data)
            fileHandle?.write(data)
        }
    }

    private static func makeStdinLineStream() -> AsyncStream<String?> {
        AsyncStream { continuation in
            let thread = Thread {
                var buffer = Data()
                let fd = FileHandle.standardInput.fileDescriptor
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(fd, &chunk, chunk.count)
                    if count <= 0 {
                        if !buffer.isEmpty, let rest = String(data: buffer, encoding: .utf8) {
                            continuation.yield(rest)
                        }
                        continuation.yield(nil)
                        continuation.finish()
                        return
                    }
                    buffer.append(contentsOf: chunk[..<count])
                    while let nl = buffer.firstIndex(of: 10) {
                        if let line = String(data: Data(buffer.prefix(upTo: nl)), encoding: .utf8) {
                            continuation.yield(line)
                        }
                        buffer.removeSubrange(...nl)
                    }
                }
            }
            thread.name = "rexplain.worker.stdin"
            thread.start()
        }
    }

    private static func readNextCommandOrTaskFinish(
        iterator: inout AsyncStream<String?>.AsyncIterator,
        currentTask: Task<Void, Never>?,
        idleDeadline: Date
    ) async -> LoopPollOutcome {
        let localIter = iterator
        let outcome: (LoopPollOutcome, AsyncStream<String?>.AsyncIterator?) = await withTaskGroup(
            of: (LoopPollOutcome, AsyncStream<String?>.AsyncIterator?).self
        ) { group in
            group.addTask {
                var iter = localIter
                if let next = await iter.next(), let line = next {
                    return (.line(line), iter)
                }
                return (.eof, iter)
            }
            if let currentTask {
                group.addTask {
                    await currentTask.value
                    return (.taskCompleted, nil)
                }
            } else {
                let remaining = max(0.1, idleDeadline.timeIntervalSinceNow)
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    return (.timedOut, nil)
                }
            }
            let first = await group.next() ?? (.eof, nil)
            group.cancelAll()
            return first
        }
        if let updatedIter = outcome.1 {
            iterator = updatedIter
        }
        return outcome.0
    }

    private static func installSignalHandlers(engine: ExplainEngine, emitter: EventEmitter) -> [DispatchSourceSignal] {
        #if canImport(Darwin)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let queue = DispatchQueue(label: "rexplain.worker.signals")
        return [SIGINT, SIGTERM].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                Task {
                    await engine.cancelActive()
                    emitter.emit(.message("cancelled", text: "Worker terminated.", errorCode: .cancelled))
                    exit(0)
                }
            }
            source.resume()
            return source
        }
        #else
        return []
        #endif
    }
}
