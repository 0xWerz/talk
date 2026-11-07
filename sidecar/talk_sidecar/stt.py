"""Parakeet speech-to-text: resident model, CPU decoding, streaming segments.

Latency budget, in the order it used to hurt:

1. Paging. MLX keeps freed GPU buffers in a cache it never hands back, so a
   resident sidecar grew to ~8 GB and macOS swapped all of it out between
   dictations; the first one after a break paid 7-23 s to page it back in.
   Now the cache is capped and cleared, and the ~1.2 GB of weights are wired
   so the OS cannot evict them.
2. Decoding. See `decode.py`: the per-frame loop runs on the CPU instead of
   making hundreds of GPU round trips.
3. Waiting for release. A `StreamSession` transcribes each stretch of speech
   as soon as the user pauses, so on release only the last few words remain.
"""

from __future__ import annotations

import gc
import threading
import time
from dataclasses import dataclass, replace
from typing import Any, Callable

import numpy as np

from .decode import DecoderState, FastTDT

SAMPLE_RATE = 16_000
# One encoder frame: 8x subsampling of a 10 ms mel hop.
FRAME = 1280
# Freed GPU buffers MLX may keep for reuse between calls.
CACHE_LIMIT = 256 * 1024**2
# Headroom wired on top of the weights for activations.
WIRED_HEADROOM = 768 * 1024**2
# After this long unused, a warm request re-touches every weight.
RETOUCH_AFTER = 20.0
# While a dictation is being recorded, poke the GPU this often. Left idle for
# a few seconds it clocks down, and the encode on release runs 2-5x slower.
GPU_KEEPALIVE = 0.25


def _log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


class Transcriber:
    """Owns the MLX model. All model touching happens under one lock."""

    def __init__(
        self,
        model_name: str,
        idle_unload_seconds: float = 900.0,
        on_state: Callable[[str], None] | None = None,
    ) -> None:
        self.model_name = model_name
        self.idle_unload_seconds = idle_unload_seconds
        self._on_state = on_state or (lambda _state: None)
        self._lock = threading.RLock()
        self._model: Any = None
        self._fast: FastTDT | None = None
        self._warmed = False
        self._last_used = 0.0
        self._stop = threading.Event()
        self._reaper = threading.Thread(target=self._reap_idle, daemon=True)
        self._reaper.start()

    # -- lifecycle ---------------------------------------------------------

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        with self._lock:
            if self._model is not None:
                self._last_used = time.monotonic()
                return
            self._on_state("loading")
            import mlx.core as mx
            from parakeet_mlx import from_pretrained

            started = time.perf_counter()
            model = from_pretrained(self._local_path() or self.model_name)
            mx.eval(model.parameters())
            self._fast = FastTDT(model) if FastTDT.supports(model) else None
            self._model = model
            # Loading casts float32 weights to bfloat16; the float32 copies sit
            # in MLX's cache until told otherwise.
            mx.clear_cache()
            mx.set_cache_limit(CACHE_LIMIT)
            self._pin(mx)
            self._last_used = time.monotonic()
            _log(
                f"loaded {self.model_name} in {time.perf_counter() - started:.1f}s, "
                f"{mx.get_active_memory() / 1024**3:.2f} GB, "
                f"decoder={'cpu' if self._fast else 'stock'}"
            )
            self._on_state("ready")

    def _local_path(self) -> str | None:
        """The downloaded model, so loading never touches the network."""
        try:
            from huggingface_hub import snapshot_download

            return snapshot_download(self.model_name, local_files_only=True)
        except Exception:
            return None  # not downloaded yet: from_pretrained will fetch it

    def _pin(self, mx: Any) -> None:
        """Wire the weights so macOS cannot compress or swap them out."""
        try:
            info = mx.device_info() if hasattr(mx, "device_info") else mx.metal.device_info()
            ceiling = int(info.get("max_recommended_working_set_size", 0)) or 0
            want = mx.get_active_memory() + WIRED_HEADROOM
            if ceiling:
                want = min(want, int(ceiling * 0.9))
            mx.set_wired_limit(want)
            _log(f"wired limit {want / 1024**3:.2f} GB")
        except Exception as exc:  # older macOS: still works, just pageable
            _log(f"could not wire model memory: {exc!r}")

    def warm(self) -> None:
        """Make sure the next transcription is fast.

        Loads if needed, and after any idle stretch runs a tiny inference so
        every weight is touched now, while the user is still talking, rather
        than on release.
        """
        with self._lock:
            self.load()
            if self._warmed and time.monotonic() - self._last_used < RETOUCH_AFTER:
                return
            self.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32), force=True)
            self._warmed = True

    def unload(self) -> None:
        with self._lock:
            if self._model is None:
                return
            self._model = None
            self._fast = None
            self._warmed = False
            gc.collect()
            try:
                import mlx.core as mx

                mx.clear_cache()
                mx.set_wired_limit(0)
            except Exception:
                pass
            self._on_state("unloaded")

    def shutdown(self) -> None:
        self._stop.set()
        self.unload()

    def _reap_idle(self) -> None:
        while not self._stop.wait(15.0):
            if self.idle_unload_seconds <= 0 or not self.loaded:
                continue
            if time.monotonic() - self._last_used >= self.idle_unload_seconds:
                self.unload()

    # -- inference ---------------------------------------------------------

    def open_stream(self) -> "StreamSession":
        return StreamSession(self)

    def transcribe(self, samples: np.ndarray, force: bool = False) -> str:
        """Transcribe mono float32 PCM at 16 kHz in one go."""
        if samples.size < SAMPLE_RATE // 10 and not force:  # a stray keypress
            return ""
        session = StreamSession(self, background=False)
        session.feed(samples)
        return session.finish()

    def _encode(self, samples: np.ndarray) -> np.ndarray:
        """Audio -> the joint's encoder projection, float32 (frames, hidden)."""
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        model = self._model
        mel = get_logmel(mx.array(samples), model.preprocessor_config)
        if mel.ndim == 2:
            mel = mx.expand_dims(mel, 0)
        features, lengths = model.encoder(mel)
        proj = model.joint.enc(features[0, : int(lengths[0])]).astype(mx.float32)
        mx.eval(proj)
        return np.array(proj)

    def _encode_window(self, samples: np.ndarray) -> np.ndarray:
        with self._lock:
            self.load()
            proj = self._encode(samples)
            self._last_used = time.monotonic()
            return proj

    def _stock(self, samples: np.ndarray) -> str:
        """Whole-clip decode through parakeet-mlx, for non-TDT models."""
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        with self._lock:
            self.load()
            mel = get_logmel(mx.array(samples), self._model.preprocessor_config)
            results = self._model.generate(mel)
            self._last_used = time.monotonic()
            mx.clear_cache()
        return results[0].text.strip() if results else ""

    def keep_gpu_awake(self) -> None:
        """A trivial GPU op: enough to stop the GPU from clocking down."""
        if self._model is None:
            return
        with self._lock:
            import mlx.core as mx

            mx.eval(mx.zeros((8,)) + 1)

    def _release(self) -> None:
        with self._lock:
            try:
                import mlx.core as mx

                mx.clear_cache()
            except Exception:
                pass


@dataclass
class _Round:
    """One speculative pass over everything heard so far."""

    end: int  # samples heard by this round
    cut: int  # frame the release re-transcribes from
    at_cut: DecoderState  # decoder state when it reached `cut`
    full: DecoderState  # decoded to the end of what it heard


class StreamSession:
    """Transcribes audio while it is still arriving, with whole-clip accuracy.

    Parakeet's encoder attends over its whole input, and it needs long left
    context: cutting the audio at pauses and decoding the pieces with a few
    seconds of context costs about a point of WER, and at some window lengths
    a stretch decodes to nothing at all. So instead:

    * While audio arrives, *rounds* re-transcribe the whole recording so far
      (past a minute, the start is committed and later rounds keep 20 s of
      left context). Each round remembers its decoder state at a cut point
      2 s before its end.
    * On release, only the last ~10 s is encoded again: 8 s before the last
      round's cut through to the end, decoded onward from the round's state
      at the cut. Everything before the cut was heard by the round with the
      whole recording as left context and at least 2 s of right context.
    * If only silence followed the last round, its transcript is the answer
      and release needs no model at all.

    The scheme follows Phonon's measurements (github.com/Infatoshi/phonon,
    sidecar/stream_asr.py), which found it indistinguishable from whole-file
    transcription on 1,351 public clips; the implementation is Talk's own.
    """

    COMMIT_AFTER = 60 * SAMPLE_RATE  # pending audio before a round commits
    COMMIT_OVERLAP = 2 * SAMPLE_RATE
    LEFT_AFTER_COMMIT = 20 * SAMPLE_RATE
    RELEASE_BEFORE = 8 * SAMPLE_RATE
    RELEASE_OVERLAP = 2 * SAMPLE_RATE
    QUIET_REUSE = SAMPLE_RATE // 10
    ROUND_EVERY = int(0.4 * SAMPLE_RATE)  # new audio between rounds
    FIRST_ROUND = SAMPLE_RATE  # don't bother before this much audio
    HOP = 320  # 20 ms energy windows

    def __init__(self, transcriber: Transcriber, background: bool = True) -> None:
        self.t = transcriber
        self._buf = np.zeros(SAMPLE_RATE * 30, dtype=np.float32)
        self._n = 0
        self._committed = DecoderState()
        self._committed_frame = 0
        self._round: _Round | None = None
        self._cond = threading.Condition()
        self._closed = False
        self._error: BaseException | None = None
        self.segments = 0  # rounds run, reported to the app
        self.release = ""  # how the release was answered, for the log
        self._gpu_used = time.monotonic()
        self._worker: threading.Thread | None = None
        if background:
            self._worker = threading.Thread(target=self._run, daemon=True)
            self._worker.start()

    @property
    def seconds(self) -> float:
        return self._n / SAMPLE_RATE

    def feed(self, samples: np.ndarray) -> None:
        samples = np.asarray(samples, dtype=np.float32).reshape(-1)
        with self._cond:
            need = self._n + samples.size
            if need > self._buf.size:
                grown = np.zeros(max(need, self._buf.size * 2), dtype=np.float32)
                grown[: self._n] = self._buf[: self._n]
                self._buf = grown
            self._buf[self._n : need] = samples
            self._n = need
            self._cond.notify()

    def cancel(self) -> None:
        with self._cond:
            self._closed = True
            self._cond.notify_all()

    def finish(self) -> str:
        """Transcribe whatever the rounds have not and return the transcript."""
        self.cancel()
        if self._worker is not None:
            self._worker.join()
        if self._error is not None:
            raise self._error
        self.t.load()
        if self.t._fast is None:  # not a TDT model: no streaming
            return self.t._stock(self._buf[: self._n])
        try:
            return self.t._fast.text(self._release())
        finally:
            self.t._release()

    # -- release -----------------------------------------------------------

    def _release(self) -> DecoderState:
        n, r = self._n, self._round
        if r is not None and (r.end >= n or self._quiet(r.end - self.QUIET_REUSE, n)):
            self.release = "reused"
            return r.full
        if r is None:
            state = _copy(self._committed)
            state.step = max(state.step, self._committed_frame)
            lo = self._left_edge(self._committed_frame)
            self.release = "whole"
        else:
            state = _copy(r.at_cut)
            lo = max(self._left_edge(self._committed_frame),
                     (r.cut * FRAME - self.RELEASE_BEFORE) // FRAME * FRAME)
            self.release = "window" if lo > 0 else "whole"
        proj = self.t._encode_window(self._buf[lo:n].copy())
        base = lo // FRAME
        return self.t._fast.decode(proj, base, base + proj.shape[0], state)

    def _left_edge(self, committed_frame: int) -> int:
        start = committed_frame * FRAME - self.LEFT_AFTER_COMMIT
        return max(0, start // FRAME * FRAME)

    def _quiet(self, start: int, end: int) -> bool:
        """True if [start, end) is clearly silence compared with the speech so far."""
        start = max(0, start)
        if end - start < self.HOP:
            return True
        history = self._energy(max(0, end - 30 * SAMPLE_RATE), end)
        floor = float(np.percentile(history, 10))
        peak = float(np.percentile(history, 99))
        if peak < 3.0 * floor:
            return False  # can't tell speech from noise: don't guess
        threshold = floor + 0.06 * (peak - floor)
        return float(self._energy(start, end).max()) < threshold

    def _energy(self, start: int, end: int) -> np.ndarray:
        frames = max(1, (end - start) // self.HOP)
        x = self._buf[start : start + frames * self.HOP]
        x = np.pad(x, (0, frames * self.HOP - x.size)).reshape(frames, self.HOP)
        return np.sqrt(np.mean(x * x, axis=1) + 1e-12)

    # -- rounds --------------------------------------------------------------

    def _due(self) -> bool:
        n = self._n
        last = self._round.end if self._round else 0
        if n < self.FIRST_ROUND or n - last < self.ROUND_EVERY:
            return False
        # Nothing but silence since the last round: it already has every word.
        return self._round is None or not self._quiet(last - self.QUIET_REUSE, n)

    def _run(self) -> None:
        try:
            while True:
                idle = False
                with self._cond:
                    while not self._closed and not self._due():
                        # Audio arrives every ~40 ms, so time the keep-alive
                        # from the last GPU use rather than from a quiet wait.
                        due = self._gpu_used + GPU_KEEPALIVE - time.monotonic()
                        if due <= 0:
                            idle = True
                            break
                        self._cond.wait(due)
                    if self._closed:
                        return
                    n = self._n
                if idle:
                    self.t.keep_gpu_awake()
                else:
                    self._run_round(n)
                self._gpu_used = time.monotonic()
        except BaseException as exc:  # surfaced from finish()
            self._error = exc

    def _run_round(self, n: int) -> None:
        start = self._committed_frame
        lo = self._left_edge(start)
        proj = self.t._encode_window(self._buf[lo:n].copy())
        base = lo // FRAME
        fast = self.t._fast
        state = _copy(self._committed)
        state.step = max(state.step, start)
        if n - start * FRAME > self.COMMIT_AFTER:
            commit = (n - self.COMMIT_OVERLAP) // FRAME
            fast.decode(proj, base, commit, state)
            self._committed, self._committed_frame = _copy(state), commit
        cut = max(self._committed_frame, (n - self.RELEASE_OVERLAP) // FRAME)
        fast.decode(proj, base, cut, state)
        at_cut = _copy(state)
        fast.decode(proj, base, base + proj.shape[0], state)
        self._round = _Round(end=n, cut=cut, at_cut=at_cut, full=state)
        self.segments += 1


def _copy(state: DecoderState) -> DecoderState:
    # The LSTM arrays are never written in place, so sharing them is safe.
    return replace(state, tokens=list(state.tokens))
