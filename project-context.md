# Oscope

Mac XY oscilloscope for chaotic analog computers.

## Goal

Display XY plots of chaotic functions from The Analog Thing, starting with the Lorenz attractor. Signal comes in as stereo line-level audio from USB interfaces in the Behringer UCA202 class (left = X, right = Y).

## Constraints

- Native Mac app. Stack is Swift unless James says otherwise.
- Input is USB audio (Core Audio), not a dedicated DAQ.
- First attractor to get right: Lorenz from The Analog Thing.
- James Mittler II owns the product decisions.
- Do the work on the Mac mini, not a cloud VM (James, 2026-11-16). The Analog Thing and a Behringer UCA202 are plugged into that Mac. Live signal checks run there.

## Out of scope for the first plan

Firmware, custom hardware, and non-Mac targets.
