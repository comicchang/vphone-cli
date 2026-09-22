// CryptexFilesystemPatcherDiskImage.swift — Disk image attach, convert and copy helpers.
//
// Split out of CryptexFilesystemPatcher.swift. The hdiutil/diskutil layer: attaching and
// detaching images, converting between RAW and UDRW, resizing, unmounting, and the
// copyfile-based volume copy used to merge a cryptex into the target volume.

import Foundation

extension CryptexFilesystemPatcher {
    func copyImageContents(source: URL, destination: URL) throws {
        // Copy everything from source volume root into destination volume root.
        let sourceRoot = source.appendingPathComponent("", isDirectory: true)
        let sourcePath = sourceRoot.path
        let destinationRoot = destination.appendingPathComponent("", isDirectory: true)

        // We delete the files first as we want to replace symlinks with actual files.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: keys) else {
            throw FirmwareManifest.ManifestError.fileNotFound(
                "Unable to read \(sourceRoot.path). Check that the image is still mounted, then try again."
            )
        }
        for case let fileURL as URL in enumerator {
            guard fileURL.path.hasPrefix(sourcePath) else { continue }

            let values = try fileURL.resourceValues(forKeys: Set(keys))
            var suffix = String(fileURL.path.dropFirst(sourcePath.count))
            if suffix.hasPrefix("/") {
                suffix.removeFirst()
            }

            let destinationPath = destinationRoot.appendingPathComponent(suffix)
            guard let ok = try? destinationPath.checkResourceIsReachable(), ok else {
                // try FileManager.default.copyItem(at: fileURL, to: destinationPath)
                let result = copyfile(
                    fileURL.path,
                    destinationPath.path,
                    nil,
                    copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_DATA)
                )
                if result < 0 {
                    print("Unable to copy \(destinationPath.path). Check permissions and free space, then try again.")
                }
                continue
            }

            let vals = try destinationPath.resourceValues(forKeys: Set(keys))
            if values.isDirectory != vals.isDirectory ||
                values.isRegularFile != vals.isRegularFile ||
                values.isSymbolicLink != vals.isSymbolicLink {
                try FileManager.default.removeItem(at: destinationPath)
                // try FileManager.default.copyItem(at: fileURL, to: destinationPath)
                let result = copyfile(
                    fileURL.path,
                    destinationPath.path,
                    nil,
                    copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_DATA)
                )
                if result < 0 {
                    print("Unable to copy \(destinationPath.path). Check permissions and free space, then try again.")
                }
            }
        }
    }

    func convertToRawImage(input: URL, output: URL) throws {
        _ = try runProcess("/usr/sbin/diskutil", [
            "image", "create", "from",
            "--format", "RAW", input.path,
            output.path
        ])

        // Resize to max
        let maxsize = try runProcess("/bin/sh", [
            "-c", "diskutil image resize --plist \"\(output.path)\" | plutil -extract max raw -o - -"
        ]).trimmingCharacters(in: ["\n"])
        _ = try runProcess("/usr/sbin/diskutil", [
            "image", "resize", "--size", maxsize, output.path
        ])
    }

    func convertToUDRWImage(input: URL, output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        _ = try runProcess("/usr/bin/hdiutil", [
            "convert",
            input.path,
            "-format", "UDRW",
            "-o", output.path
        ])
    }

    func shrinkImage(dmg: URL) throws {
        _ = try runProcess("/usr/sbin/diskutil", [
            "image",
            "resize",
            "--size", "min",
            dmg.path
        ])
    }

    func unmount(mount: String) throws {
        _ = try runProcess("/usr/sbin/diskutil", ["unmount", mount])
    }

    // attachImage returns the device and mount point
    func attachImage(path: URL, readonly: Bool = false, forceRW: Bool = false) throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = if readonly {[
            "attach",
            "-readonly",
            "-plist",
            path.path,
        ]} else {[
            "attach",
            "-plist",
            path.path,
        ]}

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            throw ProcessError.failed(process.terminationStatus, output)
        }

        let root = try parsePlist(data: data)
        guard let entries = root["system-entities"] as? [Any] else {
            throw FirmwareManifest.ManifestError.missingKey("system-entities")
        }
        for entry in entries {
            guard let entry = entry as? PlistDict,
                  let volumeKind = entry["volume-kind"] as? String,
                  volumeKind == "apfs" || volumeKind == "hfs" else {
                continue
            }
            let device = entry["dev-entry"] as? String ?? ""
            let mountPoint = entry["mount-point"] as? String ?? ""

            if forceRW {
                _ = try runProcess("/sbin/mount", ["-u", "-w", device, mountPoint])
            }
            return (device, mountPoint)
        }
        throw FirmwareManifest.ManifestError.missingKey("dev-entry or mount-point")
    }

    func detachImage(deviceNode: String) throws {
        _ = try runProcess("/usr/bin/hdiutil", ["detach", deviceNode])
    }
}
