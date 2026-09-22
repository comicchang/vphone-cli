// CryptexFilesystemPatcherSealing.swift — Trust cache, mtree and SystemVolume seal generation.
//
// Split out of CryptexFilesystemPatcher.swift. Everything that turns the merged image into a
// sealed system volume: the static trust cache, the mtree, the digest database and root hash
// produced by apfs_sealvolume, and the Ap,SystemVolumeCanonicalMetadata container.

import Foundation

extension CryptexFilesystemPatcher {
    func wrapRootHash(_ rootHashPath: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let im4pPath = tmpDir.appending(path: "metadata.root_hash")
        _ = try runProcess("/opt/homebrew/bin/ipsw", [
            "img4", "im4p", "create",
            "--type", "isys", "--version", "0",
            "-o", im4pPath.path,
            rootHashPath.path
        ])
        return im4pPath
    }

    func wrapTrustcache(_ trustcache: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let im4pPath = tmpDir.appending(path: "new.filesystem")
        _ = try runProcess("/opt/homebrew/bin/ipsw", [
            "img4", "im4p", "create",
            "--type", "trst", "--version", "1",
            "-o", im4pPath.path,
            trustcache.path
        ])
        return im4pPath
    }

    func compressCanonicalMetadata(mtree: URL, digestDb: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let targetMtree = tmpDir.appending(path: mtree.lastPathComponent)
        try FileManager.default.copyItem(at: mtree, to: targetMtree)
        let targetDigestDb = tmpDir.appending(path: digestDb.lastPathComponent)
        try FileManager.default.copyItem(at: digestDb, to: targetDigestDb)

        let archivePath = tmpDir.appending(path: "payload.aar")
        _ = try runProcess("/usr/bin/aa", [
            "archive",
            "-d", tmpDir.path,
            "-o", archivePath.path
        ])

        let im4pPath = tmpDir.appending(path: "metadata.mtree")
        _ = try runProcess("/opt/homebrew/bin/ipsw", [
            "img4", "im4p", "create",
            "--type", "msys", "--version", "0",
            "-o", im4pPath.path,
            archivePath.path
        ])
        return im4pPath
    }

    private func identifyApfsSealvolume() throws -> URL {
        let iosVersion = try getProductVersion()
        // VPHONE_SEAL_DIR (set by the CLI's `fw prepare`/`fw patch`) must agree with
        // wherever fw_prepare.sh's download_apfs_sealvolume() wrote the file; unset
        // (dev Makefile flow) falls back to the historical repo-relative `.tools/`.
        let sealDir = ProcessInfo.processInfo.environment["VPHONE_SEAL_DIR"].map { URL(fileURLWithPath: $0) }
            ?? self.vphoneCliDirectory.appending(path: ".tools")
        let path = sealDir.appendingPathComponent("apfs_sealvolume_\(iosVersion)")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw FirmwareManifest.ManifestError.fileNotFound(path.path)
        }
        guard FileManager.default.isExecutableFile(atPath: path.path) else {
            throw ProcessError.notExecutable(path.path)
        }
        return path
    }

    func createDigestAndHash(filesystem: URL, mtree: URL, remap: Bool) throws -> (URL, URL) {
        let (device, mount) = try attachImage(path: filesystem)
        defer { try? detachImage(deviceNode: device) }

        let tmpDir = try createTmpDir()
        let digestDbPath = tmpDir.appending(path: "digest.db")
        let rootHashPath = tmpDir.appending(path: "root_hash")
        let mtreeRemapPath = tmpDir.appending(path: "mtree_remap.xml")
        let sealLogPath = tmpDir.appending(path: "seal.log")

        // We want to get the nanosecond timestamp of the last modification before the mtree collection.
        // We know that we remove directories in /private/var in removeSpecificSystemFiles last.
        // Therefore, we parse the modification time of /private/var.
        let modificationTime = try parsePrivateVarTime(mtree: mtree)
        let remapContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \(remap ? """
                    <key>MODIFICATION</key>
                    <integer>\(modificationTime)</integer>
                """ : "")
            </dict>
            </plist>
            """
        print("Modification time: \(remap ? modificationTime : "none")")
        FileManager.default.createFile(atPath: mtreeRemapPath.path, contents: remapContent.data(using: .utf8))

        try unmount(mount: mount)
        let sealvolume = try identifyApfsSealvolume()
        FileManager.default.createFile(atPath: sealLogPath.path, contents: nil)
        _ = try runProcess(sealvolume.path, [
            "-R", mtreeRemapPath.path,
            "-U", digestDbPath.path, // Save digest records
            "-M", rootHashPath.path, // Save root hash
            device
        ], output: sealLogPath)
        return (digestDbPath, rootHashPath)
    }

    func parsePrivateVarTime(mtree: URL) throws -> String {
        guard let mtreeData = FileManager.default.contents(atPath: mtree.path),
              let text = String(data: mtreeData, encoding: .utf8) else {
            throw FirmwareManifest.ManifestError.fileNotFound(mtree.path)
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)

        // Find the section header for /private/var
        guard let sectionIndex = lines.firstIndex(of: "# ./private/var") else {
            throw FirmwareManifest.ManifestError.fileNotFound("/private/var")
        }

        // Look at the lines after that header until the next section header
        for line in lines[(sectionIndex + 1)...] {
            // Stop if we hit the next section
            if line.hasPrefix("# ./") {
                break
            }

            // The metadata line for /private/var starts with "var "
            guard line.hasPrefix("var ") else { continue }

            // Extract time=...
            guard let match = line.range(of: #"time=([0-9]+(?:\.[0-9]+)?)"#,
                                         options: .regularExpression) else {
                throw FirmwareManifest.ManifestError.fileNotFound("modification time for /private/var in \(mtree.path)")
            }

            let matchedText = String(line[match])
            return matchedText
                .replacingOccurrences(of: "time=", with: "")
                .replacingOccurrences(of: ".", with: "")
        }

        throw FirmwareManifest.ManifestError.fileNotFound("the /private/var entry in \(mtree.path)")
    }

    func createMtree(filesystem: URL) throws -> URL {
        let (device, mount) = try attachImage(path: filesystem, readonly: true)
        defer { try? detachImage(deviceNode: device) }

        let tmpDir = try createTmpDir()
        let mtreeFile = tmpDir.appending(path: "mtree.txt")
        FileManager.default.createFile(atPath: mtreeFile.path, contents: nil)
        _ = try runProcess("/usr/sbin/mtree", [
            "-c",
            "-p", mount,
        ], output: mtreeFile)
        return mtreeFile
    }

    func removeSpecificSystemFiles(filesystem: URL) throws -> Bool {
        let (device, mount) = try attachImage(path: filesystem, forceRW: true)
        defer { try? detachImage(deviceNode: device) }

        let removedPaths = [
            "/private/var/MobileAsset/PreinstalledAssets",
            "/private/var/MobileAsset/PreinstalledAssetsV2",
            "/private/var/staged_system_apps",
        ]
        var didEdit = false
        for path in removedPaths {
            if FileManager.default.fileExists(atPath: mount.appending(path)) {
                try FileManager.default.removeItem(atPath: mount.appending(path))
                didEdit = true
            }
        }
        return didEdit
    }

    func createTrustcache(filesystem: URL) throws -> URL {
        let (device, mount) = try attachImage(path: filesystem, readonly: true)
        defer { try? detachImage(deviceNode: device) }

        let oldTrustcache = try componentPath("StaticTrustCache")
        let oldTrustcachePath = self.restoreDir.appending(path: oldTrustcache)
        let newTrustcachePath = self.restoreDir.appending(path: "Firmware/new.trustcache")
        let tmpDir = try createTmpDir()

        let tcContainer = tmpDir.appending(path: "new.trustcache")
        _ = try runProcess("/System/Library/SecurityResearch/usr/bin/cryptexctl", [
            "generate-trust-cache", "--type", "static",
            "--base-trust-cache", oldTrustcachePath.path,
            "--output-file", tcContainer.path,
            mount
        ])

        if FileManager.default.fileExists(atPath: newTrustcachePath.path) {
            try FileManager.default.removeItem(at: newTrustcachePath)
        }
        try FileManager.default.moveItem(at: tcContainer, to: newTrustcachePath)

        return newTrustcachePath
    }
}
