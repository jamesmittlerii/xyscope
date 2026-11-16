import SwiftUI

struct ContentView: View {
    @Bindable var model: ScopeModel
    @AppStorage("optionsVisible") private var optionsVisible = true

    var body: some View {
        HStack(spacing: 0) {
            ScopeView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                #if !os(macOS)
                .ignoresSafeArea()
                #endif
            if optionsVisible {
                sidebar
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    optionsVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(optionsVisible ? "Hide Options" : "Show Options")
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.status)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.inputDevices.count > 1 {
                    Picker("Input", selection: $model.selectedDeviceID) {
                        ForEach(model.inputDevices) { device in
                            Text(deviceLabel(device)).tag(Optional(device.id))
                        }
                    }
                    .font(.caption)
                }

                if let inputError = model.inputError {
                    Text(inputError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                axis("X", gain: $model.gainX, offset: $model.offsetX, invert: $model.invertX)
                axis("Y", gain: $model.gainY, offset: $model.offsetY, invert: $model.invertY)

                sliderRow("Beam", value: $model.beam, range: 0.4...2.6, format: "%.2f")

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Persistence")
                        Spacer()
                        Text(persistenceText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Slider(value: persistenceSlider, in: 0...1)
                        .tint(Theme.phosphor)
                }

                HStack(spacing: 8) {
                    Button("Center") {
                        model.center()
                    }
                    .keyboardShortcut("0", modifiers: [.command])
                    Button("Fill") {
                        model.fill()
                    }
                    .keyboardShortcut("9", modifiers: [.command])
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 268)
        .background(Theme.sidebar)
    }

    private func axis(_ name: String, gain: Binding<Double>, offset: Binding<Double>, invert: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.phosphor)
            sliderRow("Gain", value: gain, range: 0...8, format: "%.2f")
            sliderRow("Offset", value: offset, range: -8...8, format: "%+.2f")
            Toggle("Invert", isOn: invert)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.phosphor)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range)
                .tint(Theme.phosphor)
        }
    }

    private var persistenceSlider: Binding<Double> {
        let low = log(0.05)
        let high = log(4.0)
        return Binding(
            get: { (log(model.persistence) - low) / (high - low) },
            set: { model.persistence = exp(low + $0 * (high - low)) }
        )
    }

    private var persistenceText: String {
        model.persistence < 1
            ? String(format: "%.2f s", model.persistence)
            : String(format: "%.1f s", model.persistence)
    }

    private func deviceLabel(_ device: InputDevice) -> String {
        let duplicates = model.inputDevices.filter { $0.name == device.name }.count
        if duplicates > 1 {
            return "\(device.name) (\(device.id))"
        }
        return device.name
    }
}

private enum Theme {
    static let phosphor = Color(red: 0.55, green: 0.95, blue: 0.45)
    static let sidebar = Color(red: 0.11, green: 0.11, blue: 0.11)
}
