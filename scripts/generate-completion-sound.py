#!/usr/bin/env python3
"""Generate Toccata's original, single completion chime with no external assets."""

import math
from pathlib import Path
import struct
import wave


SAMPLE_RATE = 44_100
DURATION = 0.95
PEAK = 0.28
OUTPUT = (Path(__file__).resolve().parents[1]
          / "apps/toccata-studio/Resources/Sounds/task-completed.wav")


def onset(t: float, duration: float) -> float:
    return 0.5 - 0.5 * math.cos(math.pi * min(1, max(0, t / duration)))


def sample(t: float) -> float:
    # A light lower lead-in gives the clear upper chime a rounded foundation.
    # Its initial strike fades quickly, leaving a much quieter resonant tail.
    # These are original oscillators; no recorded samples are incorporated.
    lead = 0.42 * onset(t, 0.008) * math.exp(-t / 0.038) * math.sin(2 * math.pi * 1100 * t)
    upper = 0
    body = 0
    age = t - 0.105
    if age > 0:
        attack = onset(age, 0.010)
        decay = 0.70 * math.exp(-age / 0.045) + 0.30 * math.exp(-age / 0.22)
        upper = attack * decay * math.sin(2 * math.pi * 2200 * age)
        body = 0.06 * attack * math.exp(-age / 0.075) * math.sin(2 * math.pi * 1100 * age)
    release = min(1, max(0, (DURATION - t) / 0.12))
    release = 0.5 - 0.5 * math.cos(math.pi * release)
    return (lead + upper + body) * release


def main() -> None:
    frames = [sample(i / SAMPLE_RATE) for i in range(round(SAMPLE_RATE * DURATION))]
    gain = PEAK / max(abs(value) for value in frames)
    pcm = b"".join(struct.pack("<h", round(value * gain * 32767)) for value in frames)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUTPUT), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(SAMPLE_RATE)
        audio.writeframes(pcm)
    print(f"Generated {OUTPUT} ({DURATION:.2f}s, peak {PEAK:.2f})")


if __name__ == "__main__":
    main()
