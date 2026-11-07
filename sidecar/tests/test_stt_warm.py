import time

from talk_sidecar import stt
from talk_sidecar.stt import Transcriber


def test_warm_touches_the_model_again_after_idle(monkeypatch):
    transcriber = Transcriber("fake")
    calls = []

    def load():
        transcriber._model = object()

    def transcribe(samples, force=False):
        calls.append(samples.size)
        transcriber._last_used = time.monotonic()
        return ""

    monkeypatch.setattr(transcriber, "load", load)
    monkeypatch.setattr(transcriber, "transcribe", transcribe)
    transcriber.warm()
    transcriber.warm()  # just used: nothing to do
    assert len(calls) == 1

    # After an idle stretch the weights may have been evicted; touch them.
    transcriber._last_used -= stt.RETOUCH_AFTER + 1
    transcriber.warm()
    assert len(calls) == 2

    transcriber.unload()
    transcriber.warm()
    assert len(calls) == 3
    transcriber.shutdown()
