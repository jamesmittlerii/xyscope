import Foundation
import Synchronization

/// One second of interleaved stereo. The capture thread is the only writer.
/// The main thread is the only reader.
final class SampleRing: @unchecked Sendable {
    let capacity: Int
    private let mask: UInt64
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<UInt64>(0)

    // Main thread only.
    private var readIndex: UInt64 = 0
    private var breakPending = false

    init(frameCapacity: Int = 65_536) {
        precondition(frameCapacity > 0 && frameCapacity & (frameCapacity - 1) == 0)
        capacity = frameCapacity
        mask = UInt64(frameCapacity - 1)
        storage = .allocate(capacity: frameCapacity * 2)
        storage.initialize(repeating: 0, count: frameCapacity * 2)
    }

    deinit {
        storage.deallocate()
    }

    func writtenFrames() -> UInt64 {
        writeIndex.load(ordering: .acquiring)
    }

    /// Realtime-safe. `samples` is interleaved stereo.
    func writeInterleaved(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var count = frameCount
        var source = samples
        if count > capacity {
            source = samples.advanced(by: (count - capacity) * 2)
            count = capacity
        }
        let start = writeIndex.load(ordering: .relaxed)
        for frame in 0..<count {
            let slot = Int((start &+ UInt64(frame)) & mask) * 2
            storage[slot] = source[frame * 2]
            storage[slot + 1] = source[frame * 2 + 1]
        }
        writeIndex.store(start &+ UInt64(count), ordering: .releasing)
    }

    /// Main thread. Drops whatever the display has not drawn yet and breaks the stroke.
    func discardPending() {
        readIndex = writeIndex.load(ordering: .acquiring)
        breakPending = true
    }

    /// Copies the newest frames into `destination` (interleaved).
    /// A break means the caller must not connect this batch to the previous point.
    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> (frameCount: Int, broke: Bool) {
        let head = writeIndex.load(ordering: .acquiring)
        var broke = breakPending
        breakPending = false

        var cursor = readIndex
        if head < cursor {
            cursor = head
            broke = true
        }

        var available = head &- cursor
        if available > UInt64(capacity) {
            cursor = head &- UInt64(capacity / 2)
            available = head &- cursor
            broke = true
        }
        // The stroke buffer holds one chunk. Keep the rest for the next draw and
        // stay connected. Skipping the oldest samples here is what opened gaps
        // when a frame ran late, which shows up on the iPad and not the Mac.
        if available > UInt64(maxFrames) {
            available = UInt64(maxFrames)
        }

        let count = Int(available)
        for frame in 0..<count {
            let slot = Int((cursor &+ UInt64(frame)) & mask) * 2
            destination[frame * 2] = storage[slot]
            destination[frame * 2 + 1] = storage[slot + 1]
        }
        readIndex = cursor &+ UInt64(count)
        return (count, broke)
    }

    /// Main thread. Min and max of up to `frames` recent samples, used by Fill.
    func recentExtent(frames wanted: Int) -> (minX: Float, maxX: Float, minY: Float, maxY: Float)? {
        let head = writeIndex.load(ordering: .acquiring)
        let count = min(wanted, Int(min(head, UInt64(capacity))))
        guard count >= 256 else { return nil }
        let start = head &- UInt64(count)
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var used = 0
        for frame in 0..<count {
            let slot = Int((start &+ UInt64(frame)) & mask) * 2
            let x = storage[slot]
            let y = storage[slot + 1]
            guard x.isFinite, y.isFinite else { continue }
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            used += 1
        }
        guard used >= 256 else { return nil }
        return (minX, maxX, minY, maxY)
    }

    /// Main thread. Mean of up to `frames` recent samples, used by Center.
    func recentMean(frames wanted: Int) -> (x: Float, y: Float)? {
        let head = writeIndex.load(ordering: .acquiring)
        let count = min(wanted, Int(min(head, UInt64(capacity / 2))))
        guard count >= 256 else { return nil }
        let start = head &- UInt64(count)
        var sumX: Float = 0
        var sumY: Float = 0
        for frame in 0..<count {
            let slot = Int((start &+ UInt64(frame)) & mask) * 2
            sumX += storage[slot]
            sumY += storage[slot + 1]
        }
        let scale = 1 / Float(count)
        return (sumX * scale, sumY * scale)
    }
}
