import Combine

/// StateObject supplies a lazy factory tied to view identity. The model itself
/// can use Observation; this holder only owns its lifetime. State(initialValue:)
/// would eagerly build and discard another model whenever the parent rebuilds.
@MainActor final class StableViewModel<Model>: ObservableObject {
    let value: Model

    init(_ makeValue: () -> Model) {
        value = makeValue()
    }

    /// Explicit and empty on purpose.
    ///
    /// This target deploys to iOS 15, below the isolated-deinit floor. For a
    /// generic `@MainActor` class the compiler then synthesises an executor-hop
    /// destructor, and `-O` dies in `EarlyPerfInliner` building an invalid apply
    /// for it (swiftlang/swift#89896, #88173). Declaring the destructor here stops
    /// that synthesis. Nothing needs isolation on teardown: ARC releases `value`.
    deinit {}
}
