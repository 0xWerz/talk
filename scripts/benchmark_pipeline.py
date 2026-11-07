#!/usr/bin/env python3
"""Compare first inference with and without silent warm-up using synthetic speech.

Run with: sidecar/.venv/bin/python scripts/benchmark_pipeline.py [repetitions]
Each measurement uses a fresh process and model; output contains no transcript.
"""
import json
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SAMPLES = {
    "short": "Please send the updated design to the team tomorrow morning.",
    "long": "Today we are reviewing the release plan for the new application. Please send the updated design to the team tomorrow morning, and make sure the documentation includes the latest changes. After that, we can test the entire workflow, fix any issues we find, and share the results with everyone before the end of the week.",
}
ROOT = Path(__file__).resolve().parents[1]


def words(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower())


def errors(reference, actual):
    a, b = words(reference), words(actual)
    previous = list(range(len(b) + 1))
    for i, word in enumerate(a, 1):
        current = [i]
        for j, other in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (word != other)))
        previous = current
    return previous[-1], len(a)


def worker(path, warm):
    sys.path.insert(0, str(ROOT / "sidecar"))
    import numpy as np
    import soundfile as sf
    from talk_sidecar.stt import Transcriber
    from talk_sidecar.cleanup import clean
    from talk_sidecar.config import DEFAULTS
    audio, rate = sf.read(path, dtype="float32")
    assert rate == 16000 and audio.ndim == 1
    transcriber = Transcriber(DEFAULTS["model"], idle_unload_seconds=0)
    start = time.perf_counter()
    transcriber.load()
    loaded = time.perf_counter()
    if warm:
        transcriber.warm()
    ready = time.perf_counter()
    text = clean(transcriber.transcribe(np.asarray(audio)), DEFAULTS["cleanup"])
    done = time.perf_counter()
    print(json.dumps({"load_ms": (loaded-start)*1000, "warm_ms": (ready-loaded)*1000,
                      "transcribe_ms": (done-ready)*1000, "seconds": len(audio)/rate, "text": text}))
    transcriber.shutdown()


def main():
    repetitions = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    if repetitions < 1:
        raise ValueError("repetitions must be positive")
    with tempfile.TemporaryDirectory(prefix="talk-bench-") as directory:
        results = {}
        for name, reference in SAMPLES.items():
            aiff, wav = Path(directory) / f"{name}.aiff", Path(directory) / f"{name}.wav"
            subprocess.run(["say", "-o", str(aiff), reference], check=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", str(aiff), str(wav)], check=True)
            for iteration in range(repetitions):
                for warm in ([False, True] if iteration % 2 == 0 else [True, False]):
                    result = subprocess.run([sys.executable, __file__, "--worker", str(wav), str(int(warm))],
                                            check=True, capture_output=True, text=True)
                    item = json.loads(result.stdout.strip().splitlines()[-1])
                    item["errors"], item["words"] = errors(reference, item.pop("text"))
                    results.setdefault((name, warm), []).append(item)
                    print(f"{name} {'warm' if warm else 'cold'} {iteration + 1}/{repetitions}: {item['transcribe_ms']:.0f} ms", flush=True)
        for (name, warm), rows in results.items():
            times = [r["transcribe_ms"] for r in rows]
            err = sum(r["errors"] for r in rows)
            count = sum(r["words"] for r in rows)
            print(f"{name} {'warm' if warm else 'cold'}: audio={rows[0]['seconds']:.2f}s "
                  f"median={statistics.median(times):.0f}ms range={min(times):.0f}-{max(times):.0f}ms "
                  f"load_median={statistics.median(r['load_ms'] for r in rows):.0f}ms "
                  f"warm_median={statistics.median(r['warm_ms'] for r in rows):.0f}ms "
                  f"word_errors={err}/{count} ({100*err/count:.1f}%)")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        worker(sys.argv[2], bool(int(sys.argv[3])))
    else:
        main()
