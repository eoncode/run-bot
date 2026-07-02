// AppUpdater+Checksum.swift
// AppUpdater
import CryptoKit
import Foundation

// MARK: - Cache helpers

/// Cache path helpers for the auto-update download flow.
extension AppUpdater {

    /// Returns the destination `URL` for the cached zip, creating the
    /// intermediate cache directory if needed.
    ///
    /// The destination is always `fixedZipURL` — a single fixed path at
    /// `~/Library/Caches/<schedulerIdentifier>/update.zip`. Each download
    /// overwrites the previous file; no version-stamped names accumulate.
    func cachedZipDestination() throws -> URL {
        let dest = fixedZipURL
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return dest
    }
}

// MARK: - SHA-256 verification

/// Reads `zipURL` from disk and verifies its SHA-256 digest against `expectedHex`.
///
/// Implemented as a `@concurrent` async free function so the synchronous
/// `Data(contentsOf:)` read runs on the cooperative thread pool's concurrent
/// executor rather than blocking an actor serial executor (Pillar 5).
///
/// ## `Data(contentsOf:)` is INTENTIONAL — do not refactor to streaming
///
/// The distributed zip is guaranteed small (< 10 MB for RunBot). `@concurrent`
/// already satisfies Pillar 5. Streaming would add real complexity for zero
/// practical benefit at this file size.
///
/// Throws `URLError(.cannotDecodeContentData)` on digest mismatch, or
/// propagates any `Data(contentsOf:)` error on read failure.
@concurrent
func verifyChecksum(zipURL: URL, expectedHex: String) async throws {
    let zipData   = try Data(contentsOf: zipURL)
    let digest    = SHA256.hash(data: zipData)
    let actualHex = digest.map { String(format: "%02x", $0) }.joined()
    guard actualHex == expectedHex else {
        throw URLError(.cannotDecodeContentData)
    }
}
