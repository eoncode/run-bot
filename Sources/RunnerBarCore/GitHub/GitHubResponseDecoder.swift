// GitHubResponseDecoder.swift
// RunnerBarCore

import Foundation

// MARK: - Error logging

// swiftlint:disable:next missing_docs
func logErrorBody(_ data: Data?, endpoint: String, status: Int) {
    guard let data, !data.isEmpty else { return }
    let body = String(data: data, encoding: .utf8) ?? "<non-UTF8, \(data.count)b>"
    let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
    log("HTTP \(status) \(endpoint): \(preview)")
}

// MARK: - Rate-limit response handler

/// Handles a 403 or 429 rate-limit response by forwarding to the given `RateLimitActorProtocol`.
///
/// Only arms the actor when the response is a **genuine** rate-limit signal:
/// - HTTP 429 (always a rate-limit by definition)
/// - HTTP 403 with `X-RateLimit-Remaining: 0` (primary rate limit exhausted)
/// - HTTP 403 with a `Retry-After` header (secondary / abuse rate limit)
///
/// A plain 403 with none of those signals is a **permission error** (wrong token
/// scope, revoked PAT, repo access denial) and must **not** arm the actor —
/// doing so would lock the app out of the API for up to 60 minutes even though
/// no rate limit was hit.
///
/// - Returns: `true` when this response was a genuine rate limit **and** the actor
///   was armed; `false` when the 403 is a plain permission error and the actor was
///   left unchanged.
/// - Parameter statusCode: The HTTP status code of the response.
/// - Parameter data: The response body, if any.
/// - Parameter response: The full `HTTPURLResponse`.
/// - Parameter endpoint: The endpoint string, used for logging.
/// - Parameter rateLimiter: The rate-limit actor to arm on a genuine rate-limit response.
func handleRateLimitResponse(
    statusCode: Int,
    _ data: Data?,
    response: HTTPURLResponse,
    endpoint: String,
    rateLimiter: some RateLimitActorProtocol
) async -> Bool {
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        .flatMap(Double.init)
    let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        .flatMap(Int.init)
    let resetHeader = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
        .flatMap(TimeInterval.init)

    let isRealRateLimit = statusCode == 429 || remaining == 0 || retryAfter != nil
    guard isRealRateLimit else {
        log("RateLimit › 403 permission error (not rate limit) — \(endpoint)")
        return false
    }

    let limitKind: String
    if retryAfter != nil || statusCode == 429 {
        limitKind = "secondary"
    } else {
        limitKind = "primary"
    }

    logErrorBody(data, endpoint: endpoint, status: statusCode)

    let resetAt: TimeInterval?
    if let retryAfter {
        resetAt = Date().timeIntervalSince1970 + retryAfter
    } else {
        resetAt = resetHeader
    }
    log(
        "RateLimit › ⚠️ rate limited (\(limitKind)) — \(endpoint) "
            + "status=\(statusCode) "
            + "retryAfter=\(String(describing: retryAfter)) "
            + "resetAt=\(String(describing: resetAt))"
    )
    await rateLimiter.set(resetAt: resetAt)
    return true
}

// MARK: - Pagination

/// Parses the `Link` header from a GitHub paginated response and returns the `next` URL, if any.
func extractNextURL(from header: String?) -> String? {
    guard let header else { return nil }
    for part in header.components(separatedBy: ",") {
        let segments = part.components(separatedBy: ";")
        guard segments.count >= 2 else { continue }
        let hasNextRel = segments.dropFirst().contains {
            $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
        }
        guard hasNextRel else { continue }
        let urlPart = segments[0].trimmingCharacters(in: .whitespaces)
        if urlPart.hasPrefix("<"), urlPart.hasSuffix(">") {
            return String(urlPart.dropFirst().dropLast())
        }
    }
    return nil
}
