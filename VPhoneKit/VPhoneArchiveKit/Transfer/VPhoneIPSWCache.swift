import CryptoKit
import Foundation
import VPhoneCoreKit

/// Resolves a local IPSW or downloads one into a reusable, validated cache.
/// Source archives are never rewritten. Remote downloads become visible only
/// after their BuildManifest can be read and their transfer size checks out.
public enum VPhoneIPSWCache {
    public struct Archive: Sendable {
        public let file: URL
        public let version: String
        public let build: String
        /// `SupportedProductTypes`, such as `iPhone17,3`.
        public let productTypes: [String]
        /// Every build identity's `Info.DeviceClass`, such as `vresearch101ap`.
        public let deviceClasses: Set<String>
    }

    public enum Error: Swift.Error, LocalizedError {
        case unsupportedSource(String)
        case missingFile(URL)
        case invalidManifest(URL)
        case unexpectedHTTP(URL, Int)
        case incompleteDownload(URL, expected: Int64, actual: Int64)
        case swappedSources(iPhone: URL, cloudOS: URL)
        case notIPhoneSource(URL, productTypes: [String])
        case notCloudOSSource(URL)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedSource(source): "Unsupported IPSW source: \(source). Use a local file path or an HTTP(S) URL."
            case let .missingFile(file): "IPSW not found at \(file.path). Check the path and try again."
            case let .invalidManifest(file): "\(file.path) is not a valid IPSW. Choose a different file."
            case let .unexpectedHTTP(url, _): "Unable to download the IPSW from \(url). Try again later."
            case let .incompleteDownload(url, expected, actual):
                "The IPSW download from \(url) is incomplete (\(actual) of \(expected) bytes). Try again."
            case let .swappedSources(iPhone, cloudOS):
                "The iPhone and cloudOS IPSWs are swapped: \(iPhone.lastPathComponent) is a cloudOS IPSW and \(cloudOS.lastPathComponent) is an iPhone IPSW. Swap the two sources, then try again."
            case let .notIPhoneSource(file, productTypes):
                "\(file.lastPathComponent) is not an \(VPhoneIPSWCache.iPhoneProductType) IPSW; it is for \(productTypes.isEmpty ? "no listed product" : productTypes.joined(separator: ", ")). Choose an \(VPhoneIPSWCache.iPhoneProductType) IPSW as the iPhone source."
            case let .notCloudOSSource(file):
                "\(file.lastPathComponent) is not a cloudOS IPSW: it has no \(VPhoneIPSWCache.cloudOSDeviceClass) build identity. Choose a cloudOS IPSW as the cloudOS source."
            }
        }
    }

    public static func resolve(
        _ source: String,
        in cacheDirectory: URL,
        session: URLSession = URLSession(configuration: .ephemeral),
    ) async throws -> Archive {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return try inspect(URL(fileURLWithPath: source))
        }
        if scheme == "file" {
            return try inspect(url)
        }
        guard scheme == "http" || scheme == "https" else {
            throw Error.unsupportedSource(source)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Before anything can fail: the directory is shared, and one made by a
        // sudo run must stay writable for the next run without sudo.
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: cacheDirectory)
        removeAbandonedDownloads(in: cacheDirectory)
        let cache = cacheDirectory.appendingPathComponent(cacheName(for: url))
        if let valid = try reuse(cache, in: cacheDirectory) {
            return valid
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3 * 60 * 60
        let pending = cacheDirectory.appendingPathComponent(".\(cache.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: pending) }
        guard fm.createFile(atPath: pending.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: pending)
        defer { try? output.close() }
        let (response, size) = try await download(request, into: output, session: session)
        try output.close()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Error.unexpectedHTTP(url, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if response.expectedContentLength > 0, size != response.expectedContentLength {
            throw Error.incompleteDownload(
                url,
                expected: response.expectedContentLength,
                actual: size,
            )
        }

        let metadata = try inspect(pending)
        do {
            try fm.moveItem(at: pending, to: cache)
        } catch {
            // Another machine's prepare finished the same URL first.
            if let valid = try reuse(cache, in: cacheDirectory) {
                return valid
            }
            throw error
        }
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        return Archive(
            file: cache,
            version: metadata.version,
            build: metadata.build,
            productTypes: metadata.productTypes,
            deviceClasses: metadata.deviceClasses,
        )
    }

    /// The cached archive when it is readable; an unreadable one is removed.
    private static func reuse(_ cache: URL, in _: URL) throws -> Archive? {
        guard FileManager.default.fileExists(atPath: cache.path) else { return nil }
        guard let valid = try? inspect(cache) else {
            try FileManager.default.removeItem(at: cache)
            return nil
        }
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        return valid
    }

    /// A download still in progress writes to its `.partial` file continuously.
    /// One untouched for an hour belongs to a process that was killed, and in a
    /// shared cache nothing else would ever remove it.
    private static func removeAbandonedDownloads(in cacheDirectory: URL) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        let cutoff = Date().addingTimeInterval(-60 * 60)
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
            let file = cacheDirectory.appendingPathComponent(name)
            guard let modified = try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }
            try? fm.removeItem(at: file)
        }
    }

    public static func inspect(_ file: URL) throws -> Archive {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Error.missingFile(file)
        }
        guard let data = try? VPhoneArchiveReader.readMember("BuildManifest.plist", from: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
              let version = plist["ProductVersion"] as? String, !version.isEmpty,
              let build = plist["ProductBuildVersion"] as? String, !build.isEmpty
        else {
            throw Error.invalidManifest(file)
        }
        let identities = plist["BuildIdentities"] as? [[String: Any]] ?? []
        let deviceClasses = identities.compactMap { identity in
            ((identity["Info"] as? [String: Any])?["DeviceClass"] as? String)?.lowercased()
        }
        return Archive(
            file: file,
            version: version,
            build: build,
            productTypes: plist["SupportedProductTypes"] as? [String] ?? [],
            deviceClasses: Set(deviceClasses),
        )
    }

    // MARK: - Download

    /// Writes the body into `output` chunk by chunk as URLSession delivers it,
    /// so the IPSW lands in the cache's own volume with no temporary copy.
    /// Iterating `bytes(for:)` one byte at a time was CPU-bound (issue #524),
    /// and `download(for:)` stages the file in the system temporary directory,
    /// which may be another volume. A non-200 response returns before any body.
    private static func download(
        _ request: URLRequest,
        into output: FileHandle,
        session: URLSession,
    ) async throws -> (URLResponse, Int64) {
        let task = session.dataTask(with: request)
        let writer = DownloadWriter(output: output)
        task.delegate = writer
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                writer.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// URLSession calls one task's delegate serially, and `continuation` is set
    /// before the task resumes, so the mutable state is never shared.
    private final class DownloadWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let output: FileHandle
        var continuation: CheckedContinuation<(URLResponse, Int64), Swift.Error>?
        private var response: URLResponse?
        private var written: Int64 = 0
        private var writeError: Swift.Error?

        init(output: FileHandle) {
            self.output = output
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
        ) {
            self.response = response
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            completionHandler(ok ? .allow : .cancel)
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard writeError == nil else { return }
            do {
                try output.write(contentsOf: data)
                written += Int64(data.count)
            } catch {
                writeError = error
                dataTask.cancel()
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Swift.Error?) {
            defer { continuation = nil }
            if let writeError {
                continuation?.resume(throwing: writeError)
            } else if let response, (response as? HTTPURLResponse)?.statusCode != 200 {
                // Cancelled on purpose in didReceive; the caller reports the status.
                continuation?.resume(returning: (response, 0))
            } else if let error {
                continuation?.resume(throwing: error)
            } else if let response {
                continuation?.resume(returning: (response, written))
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }

    // MARK: - Pairing

    /// The iPhone IPSW's product, and the cloudOS device class whose boot
    /// chain matches the VM's DFU hardware. The restore tree needs both.
    public static let iPhoneProductType = VPhoneFirmwareCatalog.device
    public static let cloudOSDeviceClass = "vresearch101ap"

    /// Checks each BuildManifest before anything is extracted, so a swapped
    /// or wrong IPSW fails at once with the fix instead of deep in the merge.
    public static func checkPair(iPhone: Archive, cloudOS: Archive) throws {
        let iPhoneIsPhone = iPhone.productTypes.contains(iPhoneProductType)
        let cloudOSIsCloudOS = cloudOS.deviceClasses.contains(cloudOSDeviceClass)
        if !iPhoneIsPhone, !cloudOSIsCloudOS,
           iPhone.deviceClasses.contains(cloudOSDeviceClass),
           cloudOS.productTypes.contains(iPhoneProductType)
        {
            throw Error.swappedSources(iPhone: iPhone.file, cloudOS: cloudOS.file)
        }
        guard iPhoneIsPhone else {
            throw Error.notIPhoneSource(iPhone.file, productTypes: iPhone.productTypes)
        }
        guard cloudOSIsCloudOS else {
            throw Error.notCloudOSSource(cloudOS.file)
        }
    }

    static func cacheName(for url: URL) -> String {
        let base = url.lastPathComponent
        let stem = base.lowercased().hasSuffix(".ipsw") ? String(base.dropLast(5)) : base
        let safe = String(stem.prefix(48).unicodeScalars.map { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122) || value == 45 || value == 46 || value == 95
                ? Character(scalar) : "_"
        })
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe.isEmpty ? "firmware" : safe)-\(suffix).ipsw"
    }
}
