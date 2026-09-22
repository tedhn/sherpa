import Combine

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var clickCount = 0

    func registerClick() {
        clickCount += 1
    }
}
