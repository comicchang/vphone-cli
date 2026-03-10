// IM4PHandler.swift — Wrapper around Img4tool for IM4P firmware container handling.

import Foundation
import Img4tool

/// Handles loading, extracting, and re-packaging IM4P firmware containers.
public enum IM4PHandler {
    /// Load a firmware file as IM4P or raw data.
    ///
    /// - Parameter url: Path to the firmware file.
    /// - Returns: Tuple of (extracted payload data, original IM4P if applicable).
    public static func load(contentsOf url: URL) throws -> (payload: Data, im4p: IM4P?) {
        let fileData = try Data(contentsOf: url)

        // Try to parse as IM4P first
        if let im4p = try? IM4P(fileData) {
            let payload = try im4p.payload()
            return (payload, im4p)
        }

        // Fall back to raw data
        return (fileData, nil)
    }

    /// Save patched data back to an IM4P container or as raw data.
    ///
    /// If the original was IM4P, re-packages with the same fourcc and LZFSE compression.
    /// Otherwise, writes raw bytes.
    ///
    /// - Parameters:
    ///   - patchedData: The patched payload bytes.
    ///   - originalIM4P: The original IM4P container (nil for raw files).
    ///   - url: Output file path.
    public static func save(
        patchedData: Data,
        originalIM4P: IM4P?,
        to url: URL
    ) throws {
        if let original = originalIM4P {
            // Re-package as IM4P with same fourcc and LZFSE compression
            let newIM4P = try IM4P(
                fourcc: original.fourcc,
                description: original.description,
                payload: patchedData,
                compression: "lzfse"
            )
            try newIM4P.data.write(to: url)
        } else {
            try patchedData.write(to: url)
        }
    }
}
