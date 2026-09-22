// CryptexFilesystemPatcherProcess.swift — Subprocess execution for the filesystem patcher.
//
// Split out of CryptexFilesystemPatcher.swift. Every external tool the merge drives — hdiutil,
// diskutil, tar, ldid, ipsw, aa, cryptexctl, apfs_sealvolume — runs through runProcess, and
// ProcessError is what it throws.

import Foundation

enum ProcessError: Error {
    case failed(Int32, String)
    case notExecutable(String)
}

extension CryptexFilesystemPatcher {
    func runProcess(
        _ launchPath: String,
        _ arguments: [String],
        sudo: Bool = false,
        output: URL? = nil
    ) throws -> String {
        let process = Process()
        if sudo {
            let whoami = try runProcess("/usr/bin/whoami", [])
            if !whoami.contains("root") {
                print("This step requires root. Run the command again with sudo.")
                exit(42)
            }
        }
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        if let output {
            let outFile = try FileHandle.init(forWritingTo: output)
            process.standardOutput = outFile
            process.standardError = outFile
        } else {
            process.standardOutput = outPipe
            process.standardError = outPipe
        }

        try process.run()
        process.waitUntilExit()

        let output = output == nil
            ? String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            : nil
        guard process.terminationStatus == 0 else {
            throw ProcessError.failed(process.terminationStatus, output ?? "")
        }
        return output ?? ""
    }
}
