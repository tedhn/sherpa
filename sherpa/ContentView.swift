import SwiftUI

struct ContentView: View {
    @State private var clickCount = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Sherpa")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Clicks: \(clickCount)")
                .font(.title2)
                .foregroundStyle(.secondary)

            Button("Click me") {
                clickCount += 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(minWidth: 320, minHeight: 240)
    }
}

#Preview {
    ContentView()
}
