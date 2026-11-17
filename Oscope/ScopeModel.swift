import AVFoundation
import Observation

#if os(macOS)
import CoreAudio
#endif

@Observable
final class ScopeModel: @unchecked Sendable {
    var gainX = 1.6 { didSet { storePreferences() } }
    var gainY = 1.6 { didSet { storePreferences() } }
    var offsetX = 0.0 { didSet { storePreferences() } }
    var offsetY = 0.0 { didSet { storePreferences() } }
    var invertX = true { didSet { storePreferences() } }
    var invertY = true { didSet { storePreferences() } }
    var persistence = 0.25 { didSet { storePreferences() } }
    var beam = 1.0 { didSet { storePreferences() } }
    var showGrid = false { didSet { storePreferences() } }

    var inputDevices: [InputDevice] = []
    var selectedDeviceID: String? {
        didSet {
            storePreferences()
            guard !suppressDeviceRestart, selectedDeviceID != oldValue else { return }
            beginInput()
        }
    }
    var status = "Line input"
    var inputError: String?

    let ring: SampleRing
    private let capture: AudioCapture
    private var inputRequest = 0
    private var suppressDeviceRestart = false
    #if !os(macOS)
    private var routeObserver: NSObjectProtocol?
    #endif

    init() {
        let ring = SampleRing()
        self.ring = ring
        capture = AudioCapture(ring: ring)
        inputDevices = AudioCapture.inputDevices()
        restorePreferences()
        if selectedDeviceID == nil {
            selectedDeviceID = AudioCapture.preferredDevice(in: inputDevices)
        }
        watchDevices()
        beginInput()
    }

    deinit {
        #if !os(macOS)
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        #endif
        capture.stop()
    }

    func center() {
        guard let mean = ring.recentMean(frames: 4_800) else { return }
        offsetX = -gainX * Double(mean.x)
        offsetY = -gainY * Double(mean.y)
    }

    /// Sizes each axis so the last second of signal spans most of the square plot.
    func fill() {
        guard let extent = ring.recentExtent(frames: 48_000) else { return }
        if let fitted = Self.fit(min: extent.minX, max: extent.maxX) {
            gainX = fitted.gain
            offsetX = fitted.offset
        }
        if let fitted = Self.fit(min: extent.minY, max: extent.maxY) {
            gainY = fitted.gain
            offsetY = fitted.offset
        }
    }

    private static func fit(min low: Float, max high: Float) -> (gain: Double, offset: Double)? {
        let span = high - low
        guard span > 0.01 else { return nil }
        let gain = min(0.90 / Double(span * 0.5), 8)
        let mid = Double(low + high) * 0.5
        return (gain, -gain * mid)
    }

    private enum Prefs {
        static let saved = "prefsSaved"
        static let gainX = "gainX"
        static let gainY = "gainY"
        static let offsetX = "offsetX"
        static let offsetY = "offsetY"
        static let invertX = "invertX"
        static let invertY = "invertY"
        static let persistence = "persistence"
        static let beam = "beam"
        static let showGrid = "showGrid"
        static let inputName = "inputName"
    }

    private func restorePreferences() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.saved) else { return }
        gainX = defaults.double(forKey: Prefs.gainX)
        gainY = defaults.double(forKey: Prefs.gainY)
        offsetX = defaults.double(forKey: Prefs.offsetX)
        offsetY = defaults.double(forKey: Prefs.offsetY)
        invertX = defaults.bool(forKey: Prefs.invertX)
        invertY = defaults.bool(forKey: Prefs.invertY)
        persistence = min(max(defaults.double(forKey: Prefs.persistence), 0.05), 4)
        beam = min(max(defaults.double(forKey: Prefs.beam), 0.4), 2.6)
        showGrid = defaults.bool(forKey: Prefs.showGrid)
        if let name = defaults.string(forKey: Prefs.inputName),
           let match = inputDevices.first(where: { $0.name == name }) {
            selectedDeviceID = match.id
        }
    }

    private func storePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Prefs.saved)
        defaults.set(gainX, forKey: Prefs.gainX)
        defaults.set(gainY, forKey: Prefs.gainY)
        defaults.set(offsetX, forKey: Prefs.offsetX)
        defaults.set(offsetY, forKey: Prefs.offsetY)
        defaults.set(invertX, forKey: Prefs.invertX)
        defaults.set(invertY, forKey: Prefs.invertY)
        defaults.set(persistence, forKey: Prefs.persistence)
        defaults.set(beam, forKey: Prefs.beam)
        defaults.set(showGrid, forKey: Prefs.showGrid)
        if let id = selectedDeviceID, let device = inputDevices.first(where: { $0.id == id }) {
            defaults.set(device.name, forKey: Prefs.inputName)
        }
    }

    private func beginInput() {
        inputRequest += 1
        let token = inputRequest
        inputError = nil
        guard let deviceID = selectedDeviceID ?? AudioCapture.preferredDevice(in: inputDevices) else {
            status = "No stereo input"
            inputError = CaptureError.noStereoInput.localizedDescription
            return
        }
        if selectedDeviceID != deviceID {
            suppressDeviceRestart = true
            selectedDeviceID = deviceID
            suppressDeviceRestart = false
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            openInput(deviceID, token: token)
        case .notDetermined:
            status = "Asking for microphone access…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.inputRequest == token else { return }
                    if granted {
                        self.openInput(deviceID, token: token)
                    } else {
                        self.status = "Input blocked"
                        self.inputError = Self.microphoneDeniedMessage
                    }
                }
            }
        default:
            status = "Input blocked"
            inputError = Self.microphoneDeniedMessage
        }
    }

    private static var microphoneDeniedMessage: String {
        #if os(macOS)
        "Microphone access is off for XY Oscilloscope. Turn it on in System Settings › Privacy & Security › Microphone."
        #else
        "Microphone access is off for XY Oscilloscope. Turn it on in Settings › XY Oscilloscope › Microphone."
        #endif
    }

    private func openInput(_ deviceID: String, token: Int) {
        guard inputRequest == token else { return }
        do {
            let opened = try capture.start(device: deviceID)
            let rate = Int(opened.sampleRate.rounded())
            status = "\(opened.deviceName) · \(rate) Hz · \(opened.bufferFrames) frames"
            inputError = nil
        } catch {
            status = "Input unavailable"
            inputError = error.localizedDescription
        }
    }

    private func watchDevices() {
        #if os(macOS)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.refreshDevices()
        }
        #else
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
        #endif
    }

    private func refreshDevices() {
        let devices = AudioCapture.inputDevices()
        inputDevices = devices
        let stillPresent = selectedDeviceID.map { id in devices.contains { $0.id == id } } ?? false
        if !stillPresent {
            selectedDeviceID = AudioCapture.preferredDevice(in: devices)
            return
        }
        #if !os(macOS)
        // USB route changes keep the same port UID; reopen so the engine picks up stereo.
        beginInput()
        #endif
    }
}
