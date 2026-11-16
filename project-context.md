# Oscope

Mac and iPad XY oscilloscope for chaotic analog computers.

## Goal

Display XY plots of chaotic functions from The Analog Thing, starting with the Lorenz attractor. Signal comes in as stereo line-level audio from USB interfaces in the Behringer UCA202 class (left = X, right = Y).

## Constraints

- Native Swift app for Mac and iPad.
- Input is USB audio: Core Audio HAL on Mac, AVAudioEngine + AVAudioSession on iPad. Not a dedicated DAQ.
- First attractor to get right: Lorenz from The Analog Thing.
- James Mittler II owns the product decisions.
- Live signal checks with The Analog Thing and a Behringer UCA202 run on the Mac mini (James, 2026-11-16). iPad checks use the same UCA202 through Apple’s Camera Connection Kit / USB-C adapter.

## Out of scope for the first plan

Firmware and custom hardware.
