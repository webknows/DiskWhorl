import Combine

/// View-local state, held with @StateObject.
///
/// Used instead of SwiftUI's @State: in the macOS 27 SDK @State is a macro whose compiler
/// plugin ships with Xcode but not with the Command Line Tools, so the project would only
/// build inside Xcode. `$box.value` provides the Binding where one is needed.
@MainActor
final class ViewState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
