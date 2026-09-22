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
        .padding(20)
        // A borderless window proposes no size to SwiftUI, so fittingSize
        // needs one axis pinned; width is it. The corners are drawn here, not
        // by the window — the window frame stays rectangular, and its
        // transparent corner pixels are what the panel's hasShadow traces.
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    ContentView(state: AppState())
}
