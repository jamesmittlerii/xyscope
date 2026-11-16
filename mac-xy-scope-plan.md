# Oscope build plan

Native Mac and iPad XY oscilloscope. Stereo USB line-in is the only input. The first picture that has to be right is the Lorenz butterfly from The Analog Thing. Firmware and custom hardware stay out. iPad uses the same UCA202-class interface over USB (Lightning or USB-C adapter) via AVAudioEngine; Mac keeps the Core Audio HAL path.

Numbers below are from the Behringer UCA202 user manual and The Analog Thing First Steps (v2) plus the THAT output docs. Rear-jack impedance is the project wiki’s “a few kilohms”; the manuals do not publish the resistor values.

## From the THAT to the screen

Use the rear RCA jacks. They are the sound-card outputs: passive 10:1 dividers, a few kilohms, about ±1 V at a full machine unit. The patch panel is the ±10 V machine unit. Those jacks sit far above the line-input limit and stay off the interface. The RCA cable included with the THAT fits the UCA202.

A UCA202-class interface is USB 1.1, class-compliant, and shows up in Core Audio with no driver. Line input is unbalanced RCA, about 27 kΩ, maximum 2 dBV. That limit is 1.26 V RMS, about 1.8 V peak on a sine, and it is where digital full scale sits. A ±1 V THAT output is about 0.56 of full scale, roughly 5 dB under clip, so the rear jacks go straight in. The 27 kΩ input loads the passive dividers, and the two channels will not match. Per-axis gain takes up the sag. The converter is 16-bit at 32, 44.1, or 48 kHz, which is finer than the hum and the trace width on screen.

Lock the device at 48 kHz (`kAudioDevicePropertyNominalSampleRate`). That is the top rate the UCA202 lists, and the one whose published response reaches 22 kHz (±1 dB from 10 Hz). Core Audio delivers Float32. Open the stream interleaved, two channels, and keep the map fixed: channel 0 (left, white) is horizontal, channel 1 (right, red) is vertical.

For the Lorenz front view, patch the attractor’s x to OUT X and z to OUT Z, then rear X to the left RCA and rear Z to the right RCA. First Steps calls the z/x plane the front view: wings on either side of a central crossing. The app does not know those names. It plots left against right. Any other pair (x/y, z/y) is a different projection and is not the milestone picture.

Ground. Power the THAT from the same Mac that hosts the UCA202, so the USB grounds and the RCA sleeves are one reference. Keep the RCA run short. Leave the UCA202 monitor switch off. Skip transformers: they strip the low end, and a pair of them will not phase-match, which shears an XY plot. Skip a second ground lead from the patch panel to the Mac.

Run Lorenz at normal integrator speed, mode OP. Unpatched, an integrator held at −1 reaches a machine unit in 1 ms, so the orbit sits in the audio band. The SLOW jack stretches that 100× and walks the orbit down toward the interface high-pass. The milestone uses normal speed. SLOW is a later stress case, not the first picture.

## App shape

One SwiftUI window. Four pieces, no third-party dependencies.

**Capture.** On Mac, a small Swift type owns a Core Audio HAL input via `AudioDeviceCreateIOProcID` (an input-only HAL AudioUnit is an acceptable stand-in if opening the stream that way is simpler). On iPad, the same type opens an `AVAudioEngine` input tap after configuring `AVAudioSession` for measurement / 48 kHz, so a class-compliant UCA202 shows up through Apple’s USB adapter. Choose the UCA202 by name when it is present, otherwise the default input, with a device menu only when more than one input exists. Enable input, leave output unused, and run at the device rate with no voice-processing unit and no sample-rate converter in the graph. The IO callback writes samples into the ring and returns. No allocation and no lock that can wait.

**Ring.** Single-producer, single-consumer, power-of-two, about one second of stereo frames. The IO proc is the only writer. The display thread is the only reader. If the reader falls behind, drop the oldest contiguous span and break the line. The ring only carries samples from the callback to the display. Phosphor lives in a texture, not in this buffer.

**Renderer.** Metal, in an `MTKView`. Each frame, a fullscreen pass multiplies an offscreen texture by a decay, a line strip of the samples that arrived since the last frame is drawn in clip space, and the texture is presented. At 48 kHz and 60 Hz that is about 800 new vertices a frame. The texture is what keeps a slow orbit visible. SwiftUI `Canvas` is the alternative, and it is the wrong tool for this: it redraws the trail on the CPU every frame and cannot hold a multi-second phosphor without a second, larger history.

Calibrate while filling the vertex buffer:

- `x = (invertX ? -1 : 1) * (gainX * left + offsetX)`, and the same for Y from the right channel.
- Gains are independent, because the dividers and the loading will not match.
- Offsets recenter residual DC.
- Invert corrects the THAT’s inverting integrators and a flipped axis. The published patch outputs −x and −z.
- Persistence is a time constant in seconds, turned into a per-frame multiply from the display interval, so it stays put if the sample rate changes. Span about 0.05 s to a few seconds.
- Keep the new stroke dim. The crossing is the most-visited part of the attractor and will wash out to a disk if the stroke is additive white. Intensity can be a constant for this slice; persistence is the control that matters.

**Controls.** SwiftUI sliders beside the metal view: gain, offset, and invert per axis, plus persistence. A Center button sets both offsets from a short mean of the ring so the picture sits on the origin before gain is touched.

A synthetic Lorenz source writes the same ring the HAL writes. One switch. The renderer never knows which source is live.

## What “Lorenz looks right” means

Setup for the check: First Steps Lorenz patch, mode OP, SLOW jacks open, x on left, z on right. Hold the picture for about 30 seconds.

- Two wings, similar size, both fully on screen.
- A narrow crossing between the wings.
- A thin trace, with individual turns still separable.
- The center stays put: it does not walk, pump, or collapse into the origin.
- Invert and offset make it match the First Steps front view.

These failures mean the slice is not done:

- One oval, or a hole at the origin: the orbit is under the interface high-pass (SLOW on), or another high-pass has entered the graph.
- A fuzzy thickened trace: ground hum.
- A straight line: one channel is dead.
- Flat edges at the screen border: gain too high, or the converter is clipping. The THAT overload lamp is a different clip, on the patch panel.
- A moving dot and no wings: persistence is shorter than the orbit.

The synthetic source has to pass the same picture before the THAT is connected. Its wings and crossing are the acceptance test for the renderer.

## Smallest slice after this plan

A single-window Mac app. It opens the UCA202, or the default stereo input, at 48 kHz and plots left against right. Metal phosphor, with per-axis gain, offset, invert, and one persistence control. A built-in Lorenz source feeds the same ring, so the picture can be accepted with the interface unplugged. The slice is done when that synthetic butterfly and a THAT front view, at normal speed, both meet the pass above.

Build the synthetic path and the Metal view first. Add HAL capture second. Confirm on the THAT third.

The slice stops at that picture. Recording, trigger, cursors, a time-domain view, and Z/U wait.

## Risks

**USB latency.** The UCA202 is USB 1.1. With Core Audio’s buffering, samples often arrive tens of milliseconds after they left the THAT. A free-running attractor is indifferent to that delay. It is not indifferent to gaps. A buffer smaller than the USB schedule can fill starves the callback, holes the ring, and draws a chord across the wings. Request on the order of 512–1024 frames (about 11–21 ms at 48 kHz). On a gap, break the strip. Aggregate devices and sub-10 ms buffers are outside this slice.

**DC blocking.** The 10 Hz lower edge in the UCA202 spec is the analog input, not Core Audio. First Steps already shows coupling capacitors tilting a waveform, and treats normal-speed qualitative demos, Lorenz included, as acceptable. SLOW mode is the case that fails: both channels lose their offset together and the butterfly closes around the origin. Add no high-pass in the app. A digital integrator will not honestly undo an unknown analog corner, and it boosts hum. The milestone stays at normal speed.

**Ground loops.** Unbalanced RCA plus a separate THAT supply puts line-frequency current on the sleeve. The trace thickens, often into a small ellipse when the channels pick up unequal amounts. Power the THAT and the UCA202 from the same Mac, use one short RCA cable, and leave transformers and extra ground leads out. A notch is not part of the slice: an orbit with energy near line frequency would lose that energy.

**Persistence on slow attractors.** Drawing only the newest samples shows a dot when the orbit is slow, and a blob when the fade is too long. Keep the fade in the offscreen texture, in seconds, from about 0.05 s (normal-speed Lorenz) to a few seconds (SLOW, later). Because the crossing is visited most, a bright additive stroke saturates it; the wing should build from persistence, not from a blown-out center. Break the strip across dropouts so a gap does not become a permanent diagonal on the phosphor.
