#!/usr/bin/env bash
# Removes Talk, its engine, settings and history. Asks before deleting the
# speech model, which other apps may share.
set -uo pipefail

osascript -e 'quit app "Talk"' >/dev/null 2>&1
pkill -x Talk 2>/dev/null
pkill -f "talk_sidecar --socket" 2>/dev/null

rm -rf /Applications/Talk.app "$HOME/Library/Application Support/Talk"
for service in Microphone Accessibility ListenEvent; do
  tccutil reset "$service" com.talk.dictation >/dev/null 2>&1
done
security delete-certificate -c "Talk Local Signing" >/dev/null 2>&1

MODEL="$HOME/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v2"
if [[ -d "$MODEL" ]]; then
  read -r -p "Also delete the 2.5 GB speech model? [y/N] " answer
  [[ "$answer" == [yY]* ]] && rm -rf "$MODEL"
fi

echo "Talk is uninstalled."
