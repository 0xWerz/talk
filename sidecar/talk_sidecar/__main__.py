from __future__ import annotations

import argparse
from pathlib import Path

from . import config
from .server import Server


def main() -> None:
    parser = argparse.ArgumentParser(prog="talk-sidecar")
    parser.add_argument("--socket", type=Path, default=config.SOCKET_PATH)
    parser.add_argument(
        "--warm",
        action="store_true",
        help="load and warm the model at startup instead of on first dictation",
    )
    args = parser.parse_args()

    server = Server()
    if args.warm:
        server.transcriber.warm()
    server.run(args.socket)


if __name__ == "__main__":
    main()
