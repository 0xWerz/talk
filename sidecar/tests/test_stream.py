"""StreamSession rounds and release, against a fake model.

The fake "model" emits one token per loud encoder frame, with the token id
equal to the frame's absolute index, so any frame decoded twice, skipped or
misaligned between a round and the release shows up as a wrong token list.
"""

import time

import numpy as np

from talk_sidecar.stt import FRAME, SAMPLE_RATE, StreamSession


class FakeFast:
    def decode(self, proj, base, stop, state):
        limit = min(stop, base + proj.shape[0])
        while state.step < limit:
            if proj[state.step - base] > 0:
                state.tokens.append((state.step, state.step, 1))
            state.step += 1
        return state

    def text(self, state):
        return " ".join(str(t) for t, _, _ in state.tokens)


class FakeTranscriber:
    loaded = True

    def __init__(self):
        self._fast = FakeFast()
        self.windows = []
        self.pokes = 0

    def load(self): ...
    def _release(self): ...

    def keep_gpu_awake(self):
        self.pokes += 1

    def _encode_window(self, samples):
        self.windows.append(len(samples))
        frames = int(np.ceil(len(samples) / FRAME))
        energy = [np.abs(samples[i * FRAME : (i + 1) * FRAME]).max(initial=0) for i in range(frames)]
        return (np.array(energy) > 0.05).astype(np.float32)


def speechy(seconds, rng, tail_silence=0.0):
    """Bursts of 'speech' over a little noise, frame aligned."""
    frames = int(seconds * SAMPLE_RATE / FRAME)
    loud = rng.random(frames) > 0.3
    audio = np.repeat(np.where(loud, 0.5, 0.0), FRAME).astype(np.float32)
    audio += rng.normal(0, 0.002, audio.size).astype(np.float32)
    expected = [i for i, on in enumerate(loud) if on]
    if tail_silence:
        audio = np.concatenate([audio, rng.normal(0, 0.002, int(tail_silence * SAMPLE_RATE)).astype(np.float32)])
    return audio, expected


def stream(t, audio, rounds=True):
    """Feed like the mic does, running rounds as they come due."""
    s = StreamSession(t, background=False)
    for i in range(0, len(audio), 683):
        s.feed(audio[i : i + 683])
        if rounds and s._due():
            s._run_round(s._n)
    return s


def tokens(text):
    return [int(x) for x in text.split()]


def test_release_window_stitches_onto_the_last_round():
    rng = np.random.default_rng(1)
    audio, expected = speechy(30.0, rng)
    t = FakeTranscriber()
    s = stream(t, audio)
    assert s.segments > 20
    assert tokens(s.finish()) == expected
    assert s.release == "window"
    # Only the last ~10 s is encoded again on release.
    assert t.windows[-1] <= (8 + 2 + 0.5) * SAMPLE_RATE


def test_rounds_hear_the_whole_recording():
    rng = np.random.default_rng(2)
    audio, _ = speechy(20.0, rng)
    t = FakeTranscriber()
    stream(t, audio)
    assert max(t.windows) >= 19 * SAMPLE_RATE  # a round, from the very start


def test_silence_before_release_reuses_the_last_round():
    rng = np.random.default_rng(3)
    audio, expected = speechy(6.0, rng, tail_silence=1.0)
    t = FakeTranscriber()
    s = stream(t, audio)
    encodes = len(t.windows)
    assert tokens(s.finish()) == expected
    assert s.release == "reused" and len(t.windows) == encodes  # no model on release


def test_short_clip_is_one_whole_pass():
    rng = np.random.default_rng(4)
    audio, expected = speechy(0.8, rng)
    t = FakeTranscriber()
    s = stream(t, audio)
    assert tokens(s.finish()) == expected
    assert s.release == "whole" and t.windows == [len(audio)]


def test_long_recordings_commit_and_bound_the_window():
    rng = np.random.default_rng(5)
    audio, expected = speechy(75.0, rng)
    t = FakeTranscriber()
    s = stream(t, audio)
    assert s._committed_frame > 0
    assert max(t.windows) <= (60 + 20 + 1) * SAMPLE_RATE
    assert tokens(s.finish()) == expected


def test_background_worker_matches_too():
    rng = np.random.default_rng(6)
    audio, expected = speechy(12.0, rng)
    t = FakeTranscriber()
    s = StreamSession(t)
    for i in range(0, len(audio), 800):
        s.feed(audio[i : i + 800])
        time.sleep(0.001)
    assert tokens(s.finish()) == expected
    assert s.segments >= 1


def test_gpu_is_kept_awake_while_audio_trickles_in():
    t = FakeTranscriber()
    s = StreamSession(t)
    for _ in range(12):  # 0.6 s of near-silence: no round comes due
        s.feed(np.zeros(800, np.float32))
        time.sleep(0.05)
    s.finish()
    assert t.pokes >= 2
