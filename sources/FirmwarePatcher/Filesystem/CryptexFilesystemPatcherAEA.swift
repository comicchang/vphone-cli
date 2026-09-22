// CryptexFilesystemPatcherAEA.swift — Apple Encrypted Archive handling for the OS image.
//
// Split out of CryptexFilesystemPatcher.swift. Reading an .aea file's key and auth metadata,
// decrypting it into a plain dmg, re-encrypting the rebuilt image, and the hex-dump parsing
// that turns `ipsw fw aea --info` output back into auth-data key/value pairs.

import Foundation

extension Data {
    init?(fromHexString hex: String) {
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }

        let chars = hex.map { $0 }
        let bytes = stride(from: 0, to: chars.count, by: 2)
            .map { String(chars[$0]) + String(chars[$0 + 1]) }
            .compactMap { UInt8($0, radix: 16) }

        guard hex.count / bytes.count == 2 else { return nil }
        self.init(bytes)
    }
}

extension CryptexFilesystemPatcher {
    func getAeaKey(_ path: URL, metadata: [String: String]) throws -> String {
        if let key = metadata["encryption_key"] {
            let key = String(key.dropFirst(4))
            if let unwrapped = Data(fromHexString: key),
               let encoded = String(data: unwrapped, encoding: .utf8),
               let data = Data(fromHexString: encoded) {
                return "base64:\(data.base64EncodedString())"
            }
            return key
        }

        return try runProcess("/opt/homebrew/bin/ipsw", [
            "fw", "aea",
            "--no-color",
            "--key",
            path.path,
        ]).trimmingCharacters(in: ["\n"])
    }

    func encryptAeaFile(_ path: URL, output: URL, key: String, metadata: [String: String]) throws {
        var arguments = [
            "encrypt", "-i", path.path, "-o", output.path,
            "-profile", "1", "-key-value", key,
        ]
        for (metaKey, metaValue) in metadata {
            arguments.append("-auth-data-key")
            arguments.append(metaKey)
            arguments.append("-auth-data-value")
            arguments.append(metaValue)
        }
        _ = try runProcess("/usr/bin/aea", arguments)
    }

    func decryptAeaFile(_ path: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let outputPath = tmpDir.appending(path: path.appendingPathExtension("dmg").lastPathComponent)
        _ = try runProcess("/opt/homebrew/bin/ipsw", [
            "fw", "aea",
            "-o", outputPath.path,
            path.path,
        ])
        return outputPath.appending(path: path.lastPathComponent.dropLast(4))
    }

    func getAeaMetadata(_ path: URL) throws -> [String: String] {
        let output = try runProcess("/opt/homebrew/bin/ipsw", [
            "fw", "aea",
            "--no-color",
            "--info",
            path.path,
        ])
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)

        var result: [String: String] = [:]
        var currentKey: String?
        var bodyLines: [String] = []

        func flushCurrentSection() {
            guard let key = currentKey else { return }
            result[key] = parseSectionBody(bodyLines)
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if let key = parseSectionHeader(trimmed) {
                flushCurrentSection()
                currentKey = key
                bodyLines = []
            } else {
                // Ignore banner lines before the first section
                if currentKey != nil {
                    bodyLines.append(rawLine)
                }
            }
        }

        flushCurrentSection()
        return result
    }

    private func parseSectionHeader(_ line: String) -> String? {
        // Matches both:
        // [com.apple.wkms.url]:
        // [saksKey]:
        guard line.hasPrefix("[") else { return nil }
        guard let end = line.firstIndex(of: "]") else { return nil }

        let key = String(line[line.index(after: line.startIndex)..<end])
        return key.isEmpty ? nil : key
    }

    private func parseSectionBody(_ bodyLines: [String]) -> String {
        let nonEmpty = bodyLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // If the section contains hex dump lines, parse and concatenate them.
        let hexBytes = nonEmpty.flatMap { parseHexDumpLine($0) }
        if !hexBytes.isEmpty {
            let b64Encoded = Data(hexBytes).base64EncodedString()
            return "hex:\(Data(b64Encoded.utf8).hex)"
        }

        // Otherwise treat it as plain text / JSON / whatever the section contains.
        let text = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return "hex:\(Data(text.utf8).hex)"
    }

    private func parseHexDumpLine(_ line: String) -> [UInt8] {
        // Example:
        // 0000000000000000:  0a 8d 03 0a 2f c7 ... |....|
        guard let colonIndex = line.firstIndex(of: ":") else { return [] }

        let afterColon = line[line.index(after: colonIndex)...]
        let beforeAscii = afterColon.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? afterColon

        let tokens = beforeAscii.split(whereSeparator: \.isWhitespace)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(tokens.count)

        for token in tokens {
            guard token.count == 2, let b = UInt8(token, radix: 16) else {
                return []   // not a hexdump line
            }
            bytes.append(b)
        }

        return bytes
    }
}
