import SwiftUI

@main
struct OscopeApp: App {
    @State private var model = ScopeModel()
    @AppStorage("optionsVisible") private var optionsVisible = true

    var body: some Scene {
        #if os(macOS)
        Window("XY Oscilloscope", id: "oscope") {
            ContentView(model: model)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Scope") {
                Button(optionsVisible ? "Hide Options" : "Show Options") {
                    optionsVisible.toggle()
                }
                .keyboardShortcut("\\", modifiers: [.command])
                Divider()
                Button("Center") { model.center() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("Fill") { model.fill() }
                    .keyboardShortcut("9", modifiers: [.command])
            }
        }
        #else
        WindowGroup {
            ContentView(model: model)
        }
        #endif
    }
}
