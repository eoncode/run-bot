// RunnerEditDraft+ProductionLoad.swift
// RunnerBarCore
//
// Moved from Sources/RunnerBar/Runner/RunnerEditDraft.swift (#1618).
// Depends on RunnerProxyStore being in Core — requires #1616 to be merged first.
//
// Internal visibility is intentional: the extension is in the same module as
// `RunnerEditDraft` so no `public` keyword is needed.

// MARK: - Production convenience

/// Production-layer convenience shim for `RunnerEditDraft.load`.
///
/// Bridges the protocol-typed Core API to the concrete shared store actors.
/// Call sites can use `draft.load(installPath:)` without referencing
/// `RunnerConfigStore` or `RunnerProxyStore` directly.
extension RunnerEditDraft {
    /// Loads disk state using the production `RunnerConfigStore.shared` and `RunnerProxyStore.shared`.
    @discardableResult
    mutating func load(installPath: String) async -> RunnerConfig? {
        await load(
            installPath: installPath,
            configStore: RunnerConfigStore.shared,
            proxyStore: RunnerProxyStore.shared
        )
    }
}
