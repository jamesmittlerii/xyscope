import MetalKit
import SwiftUI

struct ScopeView: NSViewRepresentable {
    var model: ScopeModel

    func makeCoordinator() -> ScopeRenderer {
        ScopeRenderer(model: model)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.layer?.isOpaque = true
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
