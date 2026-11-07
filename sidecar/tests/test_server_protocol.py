import json
import shutil
import socket
import tempfile
import threading
import time
from pathlib import Path

import numpy as np
import pytest

from talk_sidecar.server import Server


class FakeTranscriber:
    """Stands in for Parakeet so the protocol test stays fast and offline."""

    loaded = True
    idle_unload_seconds = 0
    model_name = "fake"
    seen: np.ndarray | None = None

    def transcribe(self, samples):
        FakeTranscriber.seen = samples
        return "um, hello hello world"

    def open_stream(self):
        return FakeStream(self)

    def load(self): ...
    def warm(self): ...
    def unload(self): ...
    def shutdown(self): ...


class FakeStream:
    segments = 0
    release = "whole"

    def __init__(self, transcriber):
        self.t = transcriber
        self.chunks = []
        self.cancelled = False

    @property
    def seconds(self):
        return sum(len(c) for c in self.chunks) / 16000

    def feed(self, samples):
        self.chunks.append(np.array(samples))

    def cancel(self):
        self.cancelled = True

    def finish(self):
        audio = np.concatenate(self.chunks) if self.chunks else np.zeros(0, "<f4")
        return self.t.transcribe(audio)


@pytest.fixture
def client():
    server = Server()
    server.transcriber = FakeTranscriber()
    # AF_UNIX paths cap out at ~104 bytes, well under pytest's tmp_path.
    tmp_dir = tempfile.mkdtemp(prefix="talk", dir="/tmp")
    sock_path = Path(tmp_dir) / "t.sock"

    thread = threading.Thread(target=server.run, args=(sock_path,), daemon=True)
    thread.start()
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for attempt in range(100):
        try:
            conn.connect(str(sock_path))
            break
        except (FileNotFoundError, ConnectionRefusedError):
            if attempt == 99:
                raise
            time.sleep(0.02)
    yield conn
    _pending.pop(conn.fileno(), None)
    conn.close()
    shutil.rmtree(tmp_dir, ignore_errors=True)


def send(conn, header, payload=b""):
    if payload:
        header = {**header, "bin": len(payload)}
    conn.sendall(json.dumps(header).encode() + b"\n" + payload)


_pending: dict[int, bytes] = {}


def recv(conn):
    """One reply. Bytes past the newline are kept: two replies often arrive
    in one packet, and dropping the second would hang the next recv."""
    buf = _pending.pop(conn.fileno(), b"")
    while b"\n" not in buf:
        conn.settimeout(10)
        chunk = conn.recv(4096)
        assert chunk, "server closed the connection"
        buf += chunk
    line, rest = buf.split(b"\n", 1)
    if rest:
        _pending[conn.fileno()] = rest
    return json.loads(line)


def test_ping(client):
    send(client, {"id": 1, "t": "ping"})
    reply = recv(client)
    assert reply["t"] == "pong" and reply["loaded"] is True
    assert reply["proto"] >= 2 and isinstance(reply["pid"], int)


def test_unknown_request_is_an_error_not_a_crash(client):
    send(client, {"id": 2, "t": "nonsense"})
    reply = recv(client)
    assert reply["t"] == "error" and reply["id"] == 2


def test_transcribe_roundtrip_with_binary_payload(client):
    audio = (np.sin(np.arange(16000) / 20) * 0.2).astype("<f4")
    send(client, {"id": 3, "t": "transcribe"}, audio.tobytes())
    reply = recv(client)

    assert reply["id"] == 3 and reply["t"] == "result"
    assert reply["raw"] == "um, hello hello world"
    assert reply["text"] == "Hello world"          # cleanup ran
    assert reply["audio_seconds"] == 1.0
    assert FakeTranscriber.seen.shape == (16000,)  # payload survived framing
    assert np.allclose(FakeTranscriber.seen, audio)


def test_cleanup_can_be_skipped_per_request(client):
    audio = np.zeros(8000, dtype="<f4")
    send(client, {"id": 4, "t": "transcribe", "cleanup": False}, audio.tobytes())
    assert recv(client)["text"] == "um, hello hello world"


def test_two_requests_in_one_write_are_both_answered(client):
    audio = np.zeros(1600, dtype="<f4")
    payload = (
        json.dumps({"id": 5, "t": "ping"}).encode() + b"\n"
        + json.dumps({"id": 6, "t": "transcribe", "bin": len(audio.tobytes())}).encode()
        + b"\n" + audio.tobytes()
    )
    client.sendall(payload)
    first, second = recv(client), recv(client)
    assert {first["id"], second["id"]} == {5, 6}


def test_streamed_audio_is_stitched_in_order(client):
    audio = (np.sin(np.arange(16000) / 7) * 0.3).astype("<f4")
    send(client, {"t": "stream_begin", "sid": 1})
    for chunk in np.array_split(audio, 7):
        send(client, {"t": "stream_audio", "sid": 1}, chunk.tobytes())
    send(client, {"id": 7, "t": "stream_end", "sid": 1})
    reply = recv(client)  # fire-and-forget messages produced no replies

    assert reply["id"] == 7 and reply["t"] == "result"
    assert reply["text"] == "Hello world"
    assert reply["audio_seconds"] == 1.0
    assert np.array_equal(FakeTranscriber.seen, audio)


def test_overlapping_streams_stay_separate(client):
    send(client, {"t": "stream_begin", "sid": 1})
    send(client, {"t": "stream_audio", "sid": 1}, np.ones(4000, "<f4").tobytes())
    send(client, {"t": "stream_begin", "sid": 2})  # next dictation starts early
    send(client, {"t": "stream_audio", "sid": 2}, np.zeros(3200, "<f4").tobytes())
    send(client, {"t": "stream_audio", "sid": 1}, np.ones(800, "<f4").tobytes())
    send(client, {"id": 8, "t": "stream_end", "sid": 1})
    assert recv(client)["audio_seconds"] == 0.3
    send(client, {"id": 9, "t": "stream_end", "sid": 2})
    assert recv(client)["audio_seconds"] == 0.2


def test_cancelled_stream_cannot_be_ended(client):
    send(client, {"t": "stream_begin", "sid": 3})
    send(client, {"t": "stream_audio", "sid": 3}, np.ones(4000, "<f4").tobytes())
    send(client, {"t": "stream_cancel", "sid": 3})
    send(client, {"id": 10, "t": "stream_end", "sid": 3})
    reply = recv(client)
    assert reply["id"] == 10 and reply["t"] == "error"


def test_warm_replies_with_loaded(client):
    send(client, {"id": 9, "t": "warm"})
    assert recv(client) == {"id": 9, "t": "ok", "loaded": True}
