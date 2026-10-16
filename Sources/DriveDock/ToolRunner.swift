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

    private static func execute(_ tool: URL, _ args: [String], environment: [String: String]?, timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }
        final class Flag: @unchecked Sendable { var value = false }
        let killed = Flag()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                killed.value = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let output = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        let timedOut = killed.value || process.terminationStatus == 124
        return Result(status: process.terminationStatus, output: output, timedOut: timedOut)
    }

    /// Answers the password prompt once; a second prompt means the password was wrong (exit 77).
    private static let script = #"""
    log_user 0
    match_max 1000000
    set timeout $env(DD_TIMEOUT)
    spawn -noecho {*}$argv
    set sent 0
    expect {
        -nocase "password" {
            if {$sent} { exit 77 }
            set sent 1
            send -- "$env(DD_PW)\r"
            exp_continue
        }
        eof { }
        timeout { exit 124 }
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
