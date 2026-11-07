"""Unix-socket server the Swift app talks to.

Wire format: one line of UTF-8 JSON per message. If that JSON carries a "bin"
key, exactly that many raw bytes follow the newline. Audio arrives as mono
little-endian float32 at 16 kHz.

Requests:  ping | warm | unload | reload_config | transcribe (bin = PCM)
           stream_begin | stream_audio (bin = PCM) | stream_end | stream_cancel
Responses: pong {loaded, proto, pid} | ok {loaded} | result {text, raw, ms}
           | error {message}
           status {state} is pushed unsolicited while the model loads.

Streaming: the app sends stream_begin when recording starts, stream_audio as
the microphone delivers it, and stream_end on release. The sidecar decodes
while audio arrives, so stream_end only waits on the last couple of seconds.
Messages without an "id" get no reply unless they fail.
"""

from __future__ import annotations

import contextlib
import json
import os
import socket
import threading
import time
from pathlib import Path
from typing import Any

import numpy as np

from . import cleanup, config
from .stt import SAMPLE_RATE, StreamSession, Transcriber

# Bumped whenever the app needs something an older sidecar lacks; the app
# replaces any sidecar that answers ping with a lower number.
PROTOCOL = 2


def _log(message: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {message}"
    print(line, flush=True)


class Connection:
    """Framed JSON+binary over one accepted socket."""

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._buf = bytearray()
        self._send_lock = threading.Lock()
        # Open streams by the app's stream id. Usually one; two overlap when
        # a new dictation starts before the previous one has been answered.
        self.sessions: dict[Any, StreamSession] = {}

    def _fill(self) -> bool:
        chunk = self._sock.recv(65536)
        if not chunk:
            return False
        self._buf.extend(chunk)
        return True

    def read_message(self) -> tuple[dict[str, Any], bytes] | None:
        while b"\n" not in self._buf:
            if not self._fill():
                return None
        line, _, rest = bytes(self._buf).partition(b"\n")
        self._buf = bytearray(rest)
        try:
            header = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"bad header: {exc}") from exc
        if not isinstance(header, dict):
            raise ValueError("header is not an object")

        want = int(header.get("bin", 0) or 0)
        while len(self._buf) < want:
            if not self._fill():
                return None
        payload = bytes(self._buf[:want])
        self._buf = bytearray(self._buf[want:])
        return header, payload

    def send(self, message: dict[str, Any]) -> None:
        data = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
        with self._send_lock:
            with contextlib.suppress(OSError):
                self._sock.sendall(data)


class Server:
    def __init__(self) -> None:
        self.cfg = config.ensure_written()
        self.transcriber = Transcriber(
            self.cfg["model"],
            idle_unload_seconds=float(self.cfg.get("idle_unload_seconds", 0)),
            on_state=self._broadcast_state,
        )
        self._clients: set[Connection] = set()
        self._clients_lock = threading.Lock()

    def _broadcast_state(self, state: str) -> None:
        _log(f"model {state}")
        with self._clients_lock:
            clients = list(self._clients)
        for client in clients:
            client.send({"t": "status", "state": state})

    # -- request handling --------------------------------------------------

    def _handle(self, header: dict[str, Any], payload: bytes, conn: Connection) -> None:
        kind = header.get("t")
        reply: dict[str, Any] = {"id": header.get("id")}

        if kind == "stream_audio":
            session = conn.sessions.get(header.get("sid"))
            if session is not None:  # audio for a cancelled stream is dropped
                count = len(payload) // 4
                session.feed(np.frombuffer(payload[: count * 4], dtype="<f4"))
        elif kind == "stream_begin":
            old = conn.sessions.pop(header.get("sid"), None)
            if old is not None:
                old.cancel()
            conn.sessions[header.get("sid")] = self.transcriber.open_stream()
        elif kind == "stream_end":
            self._stream_end(header, conn, reply)
        elif kind == "stream_cancel":
            session = conn.sessions.pop(header.get("sid"), None)
            if session is not None:
                session.cancel()
        elif kind == "ping":
            conn.send(
                {
                    **reply,
                    "t": "pong",
                    "loaded": self.transcriber.loaded,
                    "proto": PROTOCOL,
                    "pid": os.getpid(),
                }
            )
        elif kind == "warm":
            # Off the connection thread: a cold load takes seconds, and audio
            # for the recording that triggered it is already on its way.
            def warm() -> None:
                started = time.perf_counter()
                try:
                    self.transcriber.warm()
                    _log(f"warm request -> {int((time.perf_counter() - started) * 1000)}ms")
                    conn.send({**reply, "t": "ok", "loaded": True})
                except Exception as exc:
                    _log(f"warm failed: {exc!r}")
                    conn.send({**reply, "t": "error", "message": str(exc)})

            threading.Thread(target=warm, daemon=True).start()
        elif kind == "unload":
            self.transcriber.unload()
            conn.send({**reply, "t": "ok"})
        elif kind == "reload_config":
            self.cfg = config.load()
            self.transcriber.idle_unload_seconds = float(
                self.cfg.get("idle_unload_seconds", 0)
            )
            if self.cfg["model"] != self.transcriber.model_name:
                self.transcriber.unload()
                self.transcriber.model_name = self.cfg["model"]
            conn.send({**reply, "t": "ok"})
        elif kind == "transcribe":
            self._transcribe(header, payload, conn, reply)
        else:
            conn.send({**reply, "t": "error", "message": f"unknown request {kind!r}"})

    def _stream_end(
        self, header: dict[str, Any], conn: Connection, reply: dict[str, Any]
    ) -> None:
        started = time.perf_counter()
        session = conn.sessions.pop(header.get("sid"), None)
        if session is None:
            raise ValueError("unknown stream")
        raw = session.finish()
        self._reply_text(header, conn, reply, raw, session.seconds, started,
                         extra={"segments": session.segments, "release": session.release})

    def _reply_text(
        self,
        header: dict[str, Any],
        conn: Connection,
        reply: dict[str, Any],
        raw: str,
        seconds: float,
        started: float,
        extra: dict[str, Any] | None = None,
    ) -> None:
        if seconds < 0.1:  # a stray keypress
            raw = ""
        cleaned = (
            cleanup.clean(raw, self.cfg.get("cleanup", {}))
            if header.get("cleanup", True)
            else raw.strip()
        )
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        segments = (extra or {}).get("segments")
        streamed = (
            f", {segments} rounds, release {(extra or {}).get('release')}"
            if segments is not None else ""
        )
        _log(f"{seconds:.1f}s audio -> {elapsed_ms}ms after release{streamed} -> {cleaned[:60]!r}")
        conn.send(
            {
                **reply,
                "t": "result",
                "text": cleaned,
                "raw": raw,
                "ms": elapsed_ms,
                "audio_seconds": round(seconds, 2),
                **(extra or {}),
            }
        )

    def _transcribe(
        self,
        header: dict[str, Any],
        payload: bytes,
        conn: Connection,
        reply: dict[str, Any],
    ) -> None:
        started = time.perf_counter()
        count = len(payload) // 4
        samples = np.frombuffer(payload[: count * 4], dtype="<f4")
        seconds = count / SAMPLE_RATE

        raw = self.transcriber.transcribe(samples)
        self._reply_text(header, conn, reply, raw, seconds, started)

    # -- socket lifecycle --------------------------------------------------

    def _serve_client(self, sock: socket.socket) -> None:
        conn = Connection(sock)
        with self._clients_lock:
            self._clients.add(conn)
        try:
            while True:
                message = conn.read_message()
                if message is None:
                    return
                header, payload = message
                try:
                    self._handle(header, payload, conn)
                except Exception as exc:  # keep the connection alive
                    _log(f"error handling {header.get('t')!r}: {exc!r}")
                    conn.send(
                        {"id": header.get("id"), "t": "error", "message": str(exc)}
                    )
        except (OSError, ValueError) as exc:
            _log(f"client dropped: {exc}")
        finally:
            for session in conn.sessions.values():
                session.cancel()
            with self._clients_lock:
                self._clients.discard(conn)
            with contextlib.suppress(OSError):
                sock.close()

    def run(self, socket_path: Path | None = None) -> None:
        path = socket_path or config.SOCKET_PATH
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            # A live sidecar already owns it; a stale one we may remove.
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.connect(str(path))
            except OSError:
                path.unlink()
            else:
                probe.close()
                raise SystemExit(f"a sidecar is already listening on {path}")
            finally:
                probe.close()

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        os.chmod(path, 0o600)
        server.listen(4)
        _log(f"listening on {path}")
        try:
            while True:
                client, _ = server.accept()
                with contextlib.suppress(OSError):
                    client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
                threading.Thread(
                    target=self._serve_client, args=(client,), daemon=True
                ).start()
        except KeyboardInterrupt:
            _log("shutting down")
        finally:
            self.transcriber.shutdown()
            server.close()
            with contextlib.suppress(OSError):
                path.unlink()
