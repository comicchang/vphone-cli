import Foundation
import Security

/// A `vphone-release-<commit>` artifact from the package workflow. It holds
/// `VPhone-<commit>.zip` next to the Launchpad zip. GitHub records a SHA-256
/// digest for the artifact, which the download is checked against; the
/// bundle zip inside it then goes through the helper like a local build.
///
/// Listing works without a token. Downloading an artifact does not, even from
/// a public repository, so the user supplies one with Actions read access.
nonisolated struct VPhoneLaunchpadArtifact: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let name: String
    let commit: String
    let branch: String
    let runID: Int64
    let createdAt: Date
    let expiresAt: Date
    let size: Int64
    let sha256: String
    let downloadURL: URL

    static let namePrefix = "vphone-release-"
    static let endpoint = URL(string: "https://api.github.com/repos/Lakr233/vphone-cli/actions/artifacts?per_page=50")!

    var shortCommit: String {
        String(commit.prefix(7))
    }

    /// The store name suffix, after the bundle's own version.
    var versionSuffix: String {
        "-ci.\(shortCommit)"
    }

    var runURL: URL {
        URL(string: "https://github.com/Lakr233/vphone-cli/actions/runs/\(runID)")!
    }

    // MARK: - Listing

    static func fetch(token: String?) async throws -> [VPhoneLaunchpadArtifact] {
        let (data, response) = try await URLSession.shared.data(for: request(endpoint, token: token))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VPhoneLaunchpadError(String(localized: "Unable to load GitHub Actions builds. Try again later."))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        return payload.artifacts.compactMap { artifact in
            guard artifact.name.hasPrefix(namePrefix), !artifact.expired,
                  let digest = artifact.digest, digest.hasPrefix("sha256:"),
                  let run = artifact.workflow_run,
                  run.head_sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
            else {
                return nil
            }
            return VPhoneLaunchpadArtifact(
                id: artifact.id,
                name: artifact.name,
                commit: run.head_sha,
                branch: run.head_branch ?? "",
                runID: run.id,
                createdAt: artifact.created_at,
                expiresAt: artifact.expires_at,
                size: artifact.size_in_bytes,
                sha256: String(digest.dropFirst("sha256:".count)),
                downloadURL: artifact.archive_download_url,
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private struct Payload: Decodable {
        struct Artifact: Decodable {
            struct Run: Decodable {
                let id: Int64
                let head_branch: String?
                let head_sha: String
            }

            let id: Int64
            let name: String
            let size_in_bytes: Int64
            let archive_download_url: URL
            let expired: Bool
            let digest: String?
            let created_at: Date
            let expires_at: Date
            let workflow_run: Run?
        }

        let artifacts: [Artifact]
    }

    private static func request(_ url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("vphone-launchpad", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Download

    /// Downloads the artifact zip. Returns the file and its hex SHA-256.
    @concurrent func download(token: String, progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, String) {
        let name = name
        return try await VPhoneLaunchpadDownload.fetch(
            Self.request(downloadURL, token: token),
            as: "\(name).zip",
            refused: { status in
                switch status {
                case 401, 403:
                    VPhoneLaunchpadError(String(localized: "GitHub refused the token. Check that it can read Actions for Lakr233/vphone-cli."))
                case 404, 410:
                    VPhoneLaunchpadError(String(localized: "This build has expired on GitHub. Choose a newer one."))
                default:
                    VPhoneLaunchpadError(String(localized: "Unable to download \(name). Check your connection and try again."))
                }
            },
            progress: progress,
        )
    }

    /// Unpacks the artifact next to itself and returns the bundle zip in it.
    @concurrent static func bundleArchive(in artifact: URL) async throws -> URL {
        let directory = artifact.deletingLastPathComponent().appendingPathComponent("artifact", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", artifact.path, directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard process.terminationStatus == 0,
              let name = names.first(where: { $0.range(of: "^VPhone-.+\\.zip$", options: .regularExpression) != nil })
        else {
            throw VPhoneLaunchpadError(String(localized: "The artifact does not contain a VPhone bundle zip."))
        }
        return directory.appendingPathComponent(name)
    }
}

// MARK: - Token

/// The GitHub token for downloading artifacts, kept in the login keychain.
nonisolated enum VPhoneLaunchpadGitHubToken {
    private static var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.vphone.launchpad.github",
            kSecAttrAccount: "actions",
        ]
    }

    static func load() -> String? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VPhoneLaunchpadError(
                String(localized: "Unable to save the token in the keychain."),
                detail: SecCopyErrorMessageString(status, nil) as String?,
            )
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
