import Foundation

/// Runs command line tools with a hard timeout. smbutil and mount_smbfs only read passwords
/// from a terminal, so those run under `expect`; the password goes through the environment
/// and never shows up in the process list.
enum ToolRunner {
    struct Result {
        let status: Int32
        let output: String
        let timedOut: Bool
        /// The tool asked for the password a second time, i.e. the first one was rejected.
        var passwordRejected: Bool { status == 77 }
    }

    static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> Result {
        execute(URL(fileURLWithPath: tool), args, environment: nil, timeout: timeout)
    }

    static func runWithPassword(_ tool: String, _ args: [String], password: String, timeout: TimeInterval) -> Result {
        var env = ProcessInfo.processInfo.environment
        env["DD_PW"] = password
        env["DD_TIMEOUT"] = String(Int(timeout))
        let expectArgs = ["-f", scriptURL.path, "--", tool] + args
        // A little slack so expect reports its own timeout before we kill it.
        return execute(URL(fileURLWithPath: "/usr/bin/expect"), expectArgs, environment: env, timeout: timeout + 5)
    }

    /// Hard deadline: SIGTERM at `timeout`, SIGKILL 2 s later, and if the process still
    /// doesn't exit (stuck in the kernel, e.g. a mount call), give up on it 2 s after that.
    /// Never blocks longer than `timeout + 6` seconds, so a profile can't stay "connecting".
    private static func execute(_ tool: URL, _ args: [String], environment: [String: String]?, timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Read asynchronously: a blocking read would wait forever if a child keeps the pipe open.
        let output = LockedValue(Data())
        let reachedEnd = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                reachedEnd.signal()
            } else {
                output.modify { $0.append(chunk) }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }

        var timedOut = false
        var abandoned = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                abandoned = exited.wait(timeout: .now() + 2) == .timedOut
            }
        }
        if !abandoned {
            _ = reachedEnd.wait(timeout: .now() + 2)
        }
        reader.readabilityHandler = nil
        try? reader.close()

        let text = String(decoding: output.get(), as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        // terminationStatus may only be read once the process has exited.
        let status = abandoned ? -1 : process.terminationStatus
        return Result(status: status, output: text, timedOut: timedOut || status == 124)
    }

    /// Answers the password prompt once; a second prompt means the password was wrong (exit 77).
    private static let script = #"""
    log_user 0
    match_max 1000000
    set timeout $env(DD_TIMEOUT)
    spawn -noecho {*}$argv
    set sent 0
    # Take the spawned tool down with us – on our own timeout and when DriveDock stops us.
    trap { catch {exec kill -9 [exp_pid]}; exit 143 } {SIGTERM SIGHUP}
    expect {
        -nocase "password" {
            if {$sent} { catch {exec kill -9 [exp_pid]}; exit 77 }
            set sent 1
            send -- "$env(DD_PW)\r"
            exp_continue
        }
        eof { }
        timeout { catch {exec kill -9 [exp_pid]}; exit 124 }
    }
    puts -nonewline $expect_out(buffer)
    catch wait result
    exit [lindex $result 3]
    """#

    private static let scriptURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DriveDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("with-password.exp")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()
}
