.PHONY: setup build run test clean install

# One-time setup: create the sidecar venv and download the speech model.
setup:
	cd sidecar && uv sync
	cd sidecar && uv run python -c "from parakeet_mlx import from_pretrained; \
		from talk_sidecar.config import DEFAULTS; from_pretrained(DEFAULTS['model']); \
		print('model ready')"

build:
	./scripts/bundle.sh

run: build
	open build/Talk.app

test:
	cd sidecar && uv run pytest tests -q
	swift build --package-path app

# The same one-step install users run: engine, build, /Applications, launch.
install:
	./install.sh

clean:
	rm -rf build app/.build
