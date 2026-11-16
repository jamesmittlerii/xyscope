import MetalKit
import SwiftUI

#if os(macOS)
struct ScopeView: NSViewRepresentable {
    var model: ScopeModel

    func makeCoordinator() -> ScopeRenderer {
        ScopeRenderer(model: model)
    }

    func makeNSView(context: Context) -> MTKView {
        makeMetalView(coordinator: context.coordinator)
    }

    func updateNSView(_: MTKView, context _: Context) {
        // Model is observed by the renderer each frame; nothing to push from SwiftUI.
    }
}
#else
struct ScopeView: UIViewRepresentable {
    var model: ScopeModel

    func makeCoordinator() -> ScopeRenderer {
        ScopeRenderer(model: model)
    }

    func makeUIView(context: Context) -> MTKView {
        makeMetalView(coordinator: context.coordinator)
    }

    func updateUIView(_: MTKView, context _: Context) {
        // Model is observed by the renderer each frame; nothing to push from SwiftUI.
    }
}
#endif

private func makeMetalView(coordinator: ScopeRenderer) -> MTKView {
    let view = MTKView()
    view.device = coordinator.device
    view.delegate = coordinator
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    view.framebufferOnly = true
    view.preferredFramesPerSecond = 60
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    #if os(macOS)
    view.layer?.isOpaque = true
    #else
    view.isOpaque = true
    view.contentScaleFactor = UIScreen.main.scale
    #endif
    return view
}
