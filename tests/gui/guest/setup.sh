#!/bin/bash
# Installs the GUI packages through the approval path and creates the projects.
source "$(dirname "$0")/lib.sh"
mapfile -t packages < /usr/share/agent-os/gui-packages
change=$(agentos system package install "${packages[@]}" python3-gi python3-gi-cairo gir1.2-gtk-3.0 ffmpeg chromium --reason "phase 4 test")
id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$change")
eq "approval is granted" 0 "$(status_of agentos system change approve "$id")"
eq "the packages install" 0 "$(status_of agentos system change apply "$id")"
for project in alpha beta; do
	agentos project create "$project" --memory-max 1500M --tasks 1024 >/dev/null
done
eq "installed GUI tools add no running service" 0 "$(pgrep -c -f '^(sway|wayvnc|Xwayland)' || true)"
finish
