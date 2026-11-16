import Metal
import MetalKit
import simd

struct BeamVertex {
    var x: Float
    var y: Float
    var across: Float
    var pad: Float
}

struct PresentUniforms {
    var aspect: Float
    var showGrid: Float
    var pad: SIMD2<Float> = .zero
}

final class ScopeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let decayPipeline: MTLRenderPipelineState
    private let strokePipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let maxFrames = 4_096
    private let sampleStorage: UnsafeMutablePointer<Float>

    private var phosphor: [MTLTexture] = []
    private var page = 0
    private var lastPoint: SIMD2<Float>?
    private var lastFrameTime: CFTimeInterval = 0

    let model: ScopeModel

    init(model: ScopeModel) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            fatalError("Metal is required.")
        }
        self.device = device
        self.queue = queue
        self.model = model
        decayPipeline = Self.makePipeline(device: device, library: library, fragment: "decay_fragment", format: .rgba16Float, blend: false)
        strokePipeline = Self.makePipeline(device: device, library: library, vertex: "stroke_vertex", fragment: "stroke_fragment", format: .rgba16Float, blend: true)
        presentPipeline = Self.makePipeline(device: device, library: library, fragment: "present_fragment", format: .bgra8Unorm, blend: false)
        let vertexCount = maxFrames * 6
        guard let buffer = device.makeBuffer(length: vertexCount * MemoryLayout<BeamVertex>.stride, options: .storageModeShared) else {
            fatalError("Could not allocate the stroke buffer.")
        }
        vertexBuffer = buffer
        sampleStorage = .allocate(capacity: maxFrames * 2)
        sampleStorage.initialize(repeating: 0, count: maxFrames * 2)
        super.init()
    }

    deinit {
        sampleStorage.deallocate()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let size = view.drawableSize
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 1, height > 1,
              let drawable = view.currentDrawable,
              let presentPass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { return }

        ensureTextures(width: width, height: height)
        guard phosphor.count == 2 else { return }

        let now = CACurrentMediaTime()
        let interval = lastFrameTime == 0 ? 1.0 / 60.0 : min(now - lastFrameTime, 0.1)
        lastFrameTime = now
        let tau = max(model.persistence, 0.05)
        var decay = Float(exp(-interval / tau))
        let beamPixels = Float(model.beam) * 6

        let source = phosphor[page]
        let destination = phosphor[1 - page]
        let aspect = Float(size.width / size.height)

        let (frameCount, broke) = model.ring.read(into: sampleStorage, maxFrames: maxFrames)
        let vertexCount = writeVertices(
            frameCount: frameCount,
            broke: broke,
            aspect: aspect,
            viewport: SIMD2(Float(width), Float(height)),
            beamPixels: beamPixels
        )

        guard let phosphorPass = renderPass(destination, load: .dontCare),
              let phosphorEncoder = command.makeRenderCommandEncoder(descriptor: phosphorPass) else { return }
        phosphorEncoder.setRenderPipelineState(decayPipeline)
        phosphorEncoder.setFragmentTexture(source, index: 0)
        phosphorEncoder.setFragmentBytes(&decay, length: MemoryLayout<Float>.size, index: 0)
        phosphorEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if vertexCount >= 6 {
            phosphorEncoder.setRenderPipelineState(strokePipeline)
            phosphorEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            phosphorEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        phosphorEncoder.endEncoding()

        presentPass.colorAttachments[0].loadAction = .clear
        presentPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        presentPass.colorAttachments[0].storeAction = .store
        guard let presentEncoder = command.makeRenderCommandEncoder(descriptor: presentPass) else { return }
        presentEncoder.setRenderPipelineState(presentPipeline)
        presentEncoder.setFragmentTexture(destination, index: 0)
        var present = PresentUniforms(
            aspect: aspect,
            showGrid: model.showGrid ? 1 : 0
        )
        presentEncoder.setFragmentBytes(&present, length: MemoryLayout<PresentUniforms>.stride, index: 0)
        presentEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        presentEncoder.endEncoding()

        command.present(drawable)
        command.commit()
        page = 1 - page
    }

    private func writeVertices(
        frameCount: Int,
        broke: Bool,
        aspect: Float,
        viewport: SIMD2<Float>,
        beamPixels: Float
    ) -> Int {
        if broke {
            lastPoint = nil
        }
        let gainX = Float(model.gainX)
        let gainY = Float(model.gainY)
        let offsetX = Float(model.offsetX)
        let offsetY = Float(model.offsetY)
        let invertX = model.invertX
        let invertY = model.invertY
        let vertices = vertexBuffer.contents().bindMemory(to: BeamVertex.self, capacity: maxFrames * 6)
        var count = 0
        var anchor = lastPoint
        let limit = maxFrames * 6 - 6
        let half = max(beamPixels, 1) * 0.5

        for frame in 0..<frameCount {
            let left = sampleStorage[frame * 2]
            let right = sampleStorage[frame * 2 + 1]
            var x = gainX * left + offsetX
            var y = gainY * right + offsetY
            if invertX { x = -x }
            if invertY { y = -y }
            if aspect >= 1 {
                x /= aspect
            } else {
                y *= aspect
            }
            let point = SIMD2(x, y)
            guard point.x.isFinite, point.y.isFinite, abs(point.x) < 8, abs(point.y) < 8 else {
                anchor = nil
                continue
            }
            if let previous = anchor, count <= limit {
                let dx = (point.x - previous.x) * 0.5 * viewport.x
                let dy = (point.y - previous.y) * 0.5 * viewport.y
                let length = hypot(dx, dy)
                if length > 0.001 {
                    let px = -dy / length
                    let py = dx / length
                    let offset = SIMD2(
                        px * half / viewport.x * 2,
                        py * half / viewport.y * 2
                    )
                    func push(_ position: SIMD2<Float>, _ across: Float) {
                        vertices[count] = BeamVertex(x: position.x, y: position.y, across: across, pad: 0)
                        count += 1
                    }
                    let leftEdge = -offset
                    let rightEdge = offset
                    push(previous + leftEdge, -1)
                    push(previous + rightEdge, 1)
                    push(point + rightEdge, 1)
                    push(previous + leftEdge, -1)
                    push(point + rightEdge, 1)
                    push(point + leftEdge, -1)
                }
            }
            anchor = point
        }
        lastPoint = anchor
        return count
    }

    private func ensureTextures(width: Int, height: Int) {
        if let current = phosphor.first, current.width == width, current.height == height { return }
        phosphor = [makeTexture(width, height), makeTexture(width, height)].compactMap { $0 }
        guard phosphor.count == 2 else { return }
        clear(phosphor[0])
        clear(phosphor[1])
        page = 0
        lastPoint = nil
    }

    private func makeTexture(_ width: Int, _ height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func clear(_ texture: MTLTexture) {
        guard let command = queue.makeCommandBuffer(),
              let pass = renderPass(texture, load: .clear),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
    }

    private func renderPass(_ texture: MTLTexture, load: MTLLoadAction) -> MTLRenderPassDescriptor? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return pass
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String = "fullscreen_vertex",
        fragment: String,
        format: MTLPixelFormat,
        blend: Bool
    ) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = format
        if blend {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Could not build the \(fragment) pipeline: \(error)")
        }
    }
}
