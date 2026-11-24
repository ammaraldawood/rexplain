import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum TerminalRenderer {
    public static func currentTerminalWidth(defaultWidth: Int = 74) -> Int {
        #if canImport(Darwin)
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 20 {
            return min(100, max(50, Int(ws.ws_col) - 2))
        }
        #endif
        return defaultWidth
    }

    public static func headerString(
        detail: DetailLevel,
        modelLabel: String = "On-device",
        width: Int = currentTerminalWidth(),
        includeOSCTitle: Bool = true
    ) -> String {
        let innerWidth = max(48, width - 2)
        let border = String(repeating: "─", count: innerWidth)
        let titleColor = "\u{001B}[1;36m"
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"

        let badge = modelLabel.trimmedOrNil ?? "On-device"
        let title = "Rexplain · \(badge) · \(detail.displayName)"
        let truncated = title.count > innerWidth - 2 ? String(title.prefix(innerWidth - 3)) + "…" : title
        let pad = max(0, innerWidth - 2 - truncated.count)

        var output = includeOSCTitle ? "\u{001B}]0;\(title)\u{0007}" : ""
        output += "\(titleColor)╭\(border)╮\(reset)\n"
        output += "\(titleColor)│\(reset) \(bold)\(truncated)\(reset)\(String(repeating: " ", count: pad)) \(titleColor)│\(reset)\n"
        output += "\(titleColor)╰\(border)╯\(reset)\n\n"
        return output
    }
}

public enum StreamViewer {
    public static func run(
        streamFile: String,
        workerPID: Int32?,
        detail: DetailLevel,
        modelLabel: String = "On-device",
        cleanupDir: String? = nil
    ) -> Int32 {
        defer {
            if let cleanupDir, !cleanupDir.isEmpty {
                try? FileManager.default.removeItem(atPath: cleanupDir)
            }
        }
        return withRawTerminalIfTTY {
            streamOnce(streamFile: streamFile, workerPID: workerPID, detail: detail, initialLabel: modelLabel)
        }
    }

    private static func streamOnce(
        streamFile: String,
        workerPID: Int32?,
        detail: DetailLevel,
        initialLabel: String
    ) -> Int32 {
        var activeLabel = initialLabel
        renderPreparing(detail: detail, label: activeLabel)

        let decoder = JSONDecoder()
        var offset: UInt64 = 0
        var lineBuffer = Data()
        var startedBody = false
        var finished = false
        var lastError: RexplainEvent?
        var pendingHint: String?
        var currentBody = ""
        var exitCode: Int32 = 0
        var workerDeadSince: Date?
        var activityDeadline = Date().addingTimeInterval(300)

        while !finished && Date() < activityDeadline {
            if isQuitByte(readKeyByte(timeoutMs: 25)) {
                terminateWorker(workerPID)
                print("\n\n\u{001B}[33m[Cancelled]\u{001B}[0m")
                fflush(stdout)
                return 0
            }

            var readBytes = false
            if let fh = FileHandle(forReadingAtPath: streamFile) {
                defer { try? fh.close() }
                try? fh.seek(toOffset: offset)
                let chunk = fh.readDataToEndOfFile()
                if !chunk.isEmpty {
                    readBytes = true
                    activityDeadline = Date().addingTimeInterval(300)
                    offset += UInt64(chunk.count)
                    lineBuffer.append(chunk)
                    while let nl = lineBuffer.firstIndex(of: 10) {
                        let lineData = Data(lineBuffer.prefix(upTo: nl))
                        lineBuffer.removeSubrange(...nl)
                        guard !lineData.isEmpty,
                              let event = try? decoder.decode(RexplainEvent.self, from: lineData) else {
                            continue
                        }

                        switch event.type {
                        case "started":
                            if let hint = event.hint, !hint.isEmpty { pendingHint = hint }
                            if let label = event.modelLabel, !label.isEmpty, label != activeLabel {
                                activeLabel = label
                                if !startedBody { renderPreparing(detail: detail, label: activeLabel) }
                            }
                        case "delta":
                            clearPreparingLine(&startedBody)
                            if let text = event.text {
                                currentBody += text
                                print(text, terminator: "")
                                fflush(stdout)
                            }
                        case "replace":
                            startedBody = true
                            currentBody = event.text ?? ""
                            print("\u{001B}[2J\u{001B}[H" + TerminalRenderer.headerString(detail: detail, modelLabel: activeLabel) + currentBody, terminator: "")
                            fflush(stdout)
                        case "completed":
                            clearPreparingLine(&startedBody)
                            finished = true
                            exitCode = 0
                        case "cancelled":
                            clearPreparingLine(&startedBody)
                            print("\n\n\u{001B}[33m[Cancelled]\u{001B}[0m")
                            fflush(stdout)
                            finished = true
                            exitCode = 0
                        case "error":
                            clearPreparingLine(&startedBody)
                            lastError = event
                            finished = true
                            exitCode = 1
                        default:
                            break
                        }
                    }
                }
            }

            if !finished && !readBytes, let workerPID, workerPID > 1, !isProcessAlive(workerPID) {
                if let deadSince = workerDeadSince {
                    if Date().timeIntervalSince(deadSince) > 0.75 {
                        clearPreparingLine(&startedBody)
                        finished = true
                        if lastError == nil && currentBody.isEmpty {
                            lastError = RexplainEvent.message("error", error: "Rexplain worker exited unexpectedly before completing.", errorCode: .internalError)
                            exitCode = 1
                        }
                    }
                } else {
                    workerDeadSince = Date()
                }
            } else if readBytes {
                workerDeadSince = nil
            }
        }

        if let err = lastError {
            print("\u{001B}[1;31mRexplain error (\(err.errorCode?.rawValue ?? "error"))\u{001B}[0m\n")
            print(err.error ?? "Unknown model error.")
            print("\n\u{001B}[2mPress q, Esc, or Enter to close.\u{001B}[0m")
            fflush(stdout)
            _ = waitForDismissKey()
            return 1
        }

        if let hint = pendingHint, !hint.isEmpty {
            print("\n\n\u{001B}[2m\(hint)\u{001B}[0m", terminator: "")
        }
        print("\n\n\u{001B}[2mDone · Press q, Esc, or Enter to close.\u{001B}[0m")
        fflush(stdout)
        _ = waitForDismissKey()
        return exitCode
    }

    private static func renderPreparing(detail: DetailLevel, label: String) {
        print("\u{001B}[2J\u{001B}[H" + TerminalRenderer.headerString(detail: detail, modelLabel: label), terminator: "")
        print("\u{001B}[2mPreparing (\(label) · \(detail.displayName))… Press q or Esc to cancel.\u{001B}[0m", terminator: "")
        fflush(stdout)
    }

    private static func clearPreparingLine(_ startedBody: inout Bool) {
        guard !startedBody else { return }
        startedBody = true
        print("\r\u{001B}[2K", terminator: "")
    }

    private static func isQuitByte(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return byte == UInt8(ascii: "q") || byte == UInt8(ascii: "Q") || byte == 27 || byte == 3
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        return Darwin.kill(pid, 0) == 0 || errno != ESRCH
        #else
        return true
        #endif
    }

    private static func terminateWorker(_ pid: Int32?) {
        #if canImport(Darwin)
        guard let pid, pid > 1 else { return }
        _ = Darwin.kill(pid, SIGTERM)
        #endif
    }

    private static func withRawTerminalIfTTY<T>(_ body: () -> T) -> T {
        #if canImport(Darwin)
        guard isatty(STDIN_FILENO) != 0 else { return body() }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return body() }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        return body()
        #else
        return body()
        #endif
    }

    private static func readKeyByte(timeoutMs: Int32) -> UInt8? {
        #if canImport(Darwin)
        guard isatty(STDIN_FILENO) != 0 else {
            if timeoutMs > 0 { usleep(useconds_t(timeoutMs * 1000)) }
            return nil
        }
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&pfd, 1, timeoutMs) > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return nil }
        var byte: UInt8 = 0
        return Darwin.read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
        #else
        return nil
        #endif
    }

    public static func waitForDismissKey() -> Bool {
        #if canImport(Darwin)
        guard isatty(STDIN_FILENO) != 0 else { return true }
        return withRawTerminalIfTTY {
            while true {
                if let byte = readKeyByte(timeoutMs: 500),
                   isQuitByte(byte) || byte == 10 || byte == 13 {
                    return true
                }
            }
        }
        #else
        return true
        #endif
    }
}
