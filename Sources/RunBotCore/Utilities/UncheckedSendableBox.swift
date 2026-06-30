/// A lightweight wrapper that asserts `Sendable` conformance for a value whose
/// thread-safety is guaranteed by the call site but cannot be expressed in the
/// type system (e.g. Objective-C types that have no `Sendable` conformance).
///
/// Use sparingly — only when you own the synchronisation invariant and can
/// document it clearly at the capture site.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
