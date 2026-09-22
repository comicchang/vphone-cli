// CryptexFilesystemPatcherGuestPayload.swift — Guest payload injection into the merged volume.
//
// Split out of CryptexFilesystemPatcher.swift. These are the steps that write files into the
// mounted target volume: dyld symlinks, GPU driver bundle, the mobileactivationd and
// launchd_cache_loader patches, vphoned, the binpack, and the LaunchDaemons that start them.

import Foundation
import VPhoneCore

extension CryptexFilesystemPatcher {
    func patchLaunchdCacheLoader(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let launchdCacheLoaderPath = target.appending(path: "/usr/libexec/launchd_cache_loader")
        let pythonPath = try resources.pythonExecutable()
        let patcherPath = resources.cfwPy
        _ = try runProcess(pythonPath.path, [
            patcherPath.path, "patch-launchd-cache-loader",
            launchdCacheLoaderPath.path
        ])
        _ = try runProcess("/bin/chmod", ["0755", launchdCacheLoaderPath.path])

        let signingCertificatePath = cfwInput.appending(path: "cfw_input/signcert.p12")
        _ = try runProcess("/opt/homebrew/bin/ldid", [
            "-S", "-M", "-K\(signingCertificatePath.path)",
            "-Icom.apple.launchd_cache_loader",
            launchdCacheLoaderPath.path
        ])
    }

    func injectLaunchDaemons(targetMount: String, cfwInput: URL, vphoned: Bool = true, cfw: Bool = true) throws {
        let target = URL.init(filePath: targetMount)
        let scriptDir = resources.scriptsDir

        let tmpDir = try createTmpDir()
        let launchdPath = tmpDir.appending(path: "launchd.plist")
        let launchDaemonsPath = tmpDir.appending(path: "launchDaemons")
        let launchdOgPath = target.appending(path: "/System/Library/xpc/launchd.plist")
        try FileManager.default.createDirectory(at: launchDaemonsPath, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: launchdOgPath, to: launchdPath)

        if vphoned {
            let vphonedSrc = scriptDir.appendingPathComponent("vphoned")
            let vphonedLaunchdPlist = vphonedSrc.appending(path: "vphoned.plist")
            try FileManager.default.copyItem(
                at: vphonedLaunchdPlist,
                to: target.appending(path: "System/Library/LaunchDaemons/vphoned.plist")
            )
            try FileManager.default.copyItem(
                at: vphonedLaunchdPlist,
                to: launchDaemonsPath.appending(path: vphonedLaunchdPlist.lastPathComponent)
            )
        }
        if cfw {
            let launchDaemonsDir = cfwInput.appending(path: "cfw_input/jb/LaunchDaemons")
            let launchDaemons = try FileManager.default.contentsOfDirectory(atPath: launchDaemonsDir.path)
            for filename in launchDaemons {
                let launchDaemonUrl = launchDaemonsDir.appending(component: filename)
                let filename = launchDaemonUrl.lastPathComponent
                let fsTarget = target.appending(path: "System/Library/LaunchDaemons/\(filename)")
                try FileManager.default.copyItem(at: launchDaemonUrl, to: fsTarget)
                try FileManager.default.copyItem(at: launchDaemonUrl, to: launchDaemonsPath.appending(path: filename))
            }
        }

        let pythonPath = try resources.pythonExecutable()
        _ = try runProcess(pythonPath.path, [
            resources.cfwPy.path, "inject-daemons",
            launchdPath.path, launchDaemonsPath.path
        ])
        try FileManager.default.moveItem(at: launchdPath, to: launchdOgPath)
        _ = try runProcess("/bin/chmod", ["0644", launchdOgPath.path])
    }

    func addExtraServices(targetMount: String, cfwInput: URL) throws {
        _ = try runProcess("/usr/bin/tar", [
            "--preserve-permissions",
            "-xf", cfwInput.appending(path: "cfw_input/jb/iosbinpack64.tar").path,
            "-C", targetMount
        ])
    }

    func addVphoned(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let scriptDir = resources.scriptsDir
        let vphonedSrc = scriptDir.appendingPathComponent("vphoned")
        // vphonedSrc (bundled source) is read-only inside a packaged .app, so the
        // compiled binary must land in a writable temp dir, not next to the source.
        let buildDir = try createTmpDir()
        let vphonedBin = buildDir.appendingPathComponent("vphoned")

        try buildVphoned(vphonedSrc: vphonedSrc, vphonedBin: vphonedBin)
        defer { try? FileManager.default.removeItem(at: vphonedBin) }

        // Sign
        let targetBin = target.appending(path: "/usr/bin/vphoned")
        try FileManager.default.copyItem(at: vphonedBin, to: targetBin)
        let signingCertificatePath = cfwInput.appending(path: "cfw_input/signcert.p12")
        _ = try runProcess("/opt/homebrew/bin/ldid", [
            "-S\(vphonedSrc.appendingPathComponent("entitlements.plist").path)",
            "-M", "-K\(signingCertificatePath.path)",
            targetBin.path
        ])
        _ = try runProcess("/bin/chmod", ["0755", targetBin.path])
    }

    func buildVphoned(vphonedSrc: URL, vphonedBin: URL) throws {
        let srcURLs = try FileManager.default.contentsOfDirectory(
            at: vphonedSrc,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "m" }

        var args = [
            "-sdk", "iphoneos", "clang",
            "-arch", "arm64",
            "-Os",
            "-fobjc-arc",
            "-I\(vphonedSrc.path)",
            "-I\(vphonedSrc.appendingPathComponent("vendor/libarchive").path)",
            "-DLESS=1",
            "-o", vphonedBin.path
        ]
        args.append(contentsOf: srcURLs.map { $0.path })
        args.append(contentsOf: [
            "-larchive",
            "-lsqlite3",
            "-framework", "Foundation",
            "-framework", "Security",
            "-framework", "CoreServices"
        ])

        _ = try runProcess("/usr/bin/xcrun", args)
    }

    func addGpuDriver(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)

        let gpuTarPath = cfwInput.appending(path: "cfw_input/custom/AppleParavirtGPUMetalIOGPUFamily.tar")
        _ = try runProcess("/usr/bin/tar", [
            "--preserve-permissions",
            "-xf", gpuTarPath.path,
            "-C", target.path
        ])

        let bundle = target.appending(path: "/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle")
        // Clean macOS resource fork files (._* files from tar xattrs)
        _ = try? runProcess("/usr/bin/find", [bundle.path, "-name", "._*", "-delete"])
        _ = try runProcess("/usr/sbin/chown", ["-R", "0:0", bundle.path])
        for path in [
            bundle.path,
            bundle.appending(path: "/libAppleParavirtCompilerPluginIOGPUFamily.dylib").path,
            bundle.appending(path: "/AppleParavirtGPUMetalIOGPUFamily").path,
            bundle.appending(path: "/_CodeSignature").path,
        ] {
            _ = try runProcess("/bin/chmod", ["0755", path])
        }
        for path in [
            bundle.appending(path: "/_CodeSignature/CodeResources").path,
            bundle.appending(path: "/Info.plist").path
        ] {
            _ = try runProcess("/bin/chmod", ["0644", path])
        }
    }

    func patchMobileActivation(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let mobileActivationdPath = target.appending(path: "/usr/libexec/mobileactivationd")
        let pythonPath = try resources.pythonExecutable()
        _ = try runProcess(pythonPath.path, [
            resources.cfwPy.path, "patch-mobileactivationd",
            mobileActivationdPath.path
        ])
        _ = try runProcess("/bin/chmod", ["0755", mobileActivationdPath.path])

        let signingCertificatePath = cfwInput.appending(path: "cfw_input/signcert.p12")
        _ = try runProcess("/opt/homebrew/bin/ldid", [
            "-S", "-M", "-K\(signingCertificatePath.path)",
            mobileActivationdPath.path
        ])
    }

    func addDyldSymlinks(targetMount: String) throws {
        let target = URL.init(filePath: targetMount)
        _ = try runProcess("/bin/ln", [
            "-sf", "../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
            target.appending(path: "/System/Library/Caches/com.apple.dyld").path
        ])
        _ = try runProcess("/bin/ln", [
            "-sf", "../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld",
            target.appending(path: "/System/DriverKit/System/Library/dyld").path
        ])
    }
}
