import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Sherpa")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Clicks: \(state.clickCount)")
                .font(.title2)
                .foregroundStyle(.secondary)

            Button("Click me") {
                state.registerClick()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(minWidth: 320, minHeight: 240)
    }
}

#Preview {
    ContentView(state: AppState())
}
