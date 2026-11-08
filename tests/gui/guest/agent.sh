#!/bin/bash
# The Phase 4 exit criterion, run as a project agent inside its own sandbox.
source "$(dirname "$0")/lib.sh"
s=agent-run
artifacts=$projects/alpha/artifacts/gui/$s
log=$artifacts/logs/app-1.log

eq "start" 0 "$(status_of agentos-gui start "$s" --size 1280x720)"
eq "state is running" running "$(state alpha "$s")"
eq "application starts" 1 "$(agentos-gui run "$s" -- python3 "$app" --animate)"
eq "window appears" 0 "$(status_of agentos-gui wait "$s" --window agentostest)"
eventually "app reports ready" ready head -1 "$log"

probe() { pixel "$(agentos-gui screenshot "$s")" 20 20; }
eventually "app paints red before input" "255 0 0" probe
eq "click is accepted" 0 "$(status_of agentos-gui click "$s" 640 100)"
eventually "the app received the click" "clicked 1 640 100" sed -n 2p "$log"
eventually "the screen shows the click" "0 255 0" probe

text='Hello, World! 123 ~`[]{}'
eq "typing is accepted" 0 "$(status_of agentos-gui type "$s" "$text")"
eq "key press is accepted" 0 "$(status_of agentos-gui key "$s" Return)"
eventually "typed text reaches the app exactly" "text $text" grep '^text' "$log"
eq "non-ASCII typing is refused" 1 "$(status_of agentos-gui type "$s" 'héllo')"
eq "a click outside the screen is refused" 1 "$(status_of agentos-gui click "$s" 5000 10)"

first=$artifacts/screenshots/0001.png
eq "screenshot has the session size" "1280x720" "$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x "$first")"

eq "recording starts" 0 "$(status_of agentos-gui record start "$s")"
sleep 3
eq "recording stops" 0 "$(status_of agentos-gui record stop "$s")"
eq "a session keeps one recording" 1 "$(status_of agentos-gui record start "$s")"
eq "recording is h264" h264 "$(ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "$artifacts/recording.mkv")"
distinct=$(ffmpeg -v error -i "$artifacts/recording.mkv" -f framemd5 - | grep -v '^#' | awk '{print $6}' | sort -u | wc -l)
between "recording holds distinct frames" 5 100000 "$distinct"

eq "Escape reaches the app" 0 "$(status_of agentos-gui key "$s" Escape)"
agentos-gui wait "$s" --app 1
eq "wait returns the app's exit status" 7 "$?"
(cd /tmp && AOS_MARK=marked PATH=/nowhere:$PATH agentos-gui run "$s" -- bash -c 'echo "$AOS_MARK $PWD ${PATH%%:*} $WAYLAND_DISPLAY"' >/dev/null)
eventually "an application gets the caller's environment and the session's display" "marked /tmp /nowhere wayland-1" cat "$artifacts/logs/app-2.log"
printf 'not json\n[1]\n{"op":"windows"\n' | while IFS= read -r line; do
	python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode()+b"\n"); s.recv(99)' "/tmp/gui/$s/control.sock" "$line"
done
eq "malformed requests leave the session running" running "$(state alpha "$s")"
eq "a test result can be stored" 0 "$(status_of agentos-gui result "$s" pass --detail "agent flow")"
eq "stop reports the state" stopped "$(agentos-gui stop "$s")"
eq "stop is idempotent" stopped "$(agentos-gui stop "$s")"
eq "runtime directory is gone" 0 "$(status_of test ! -e "/tmp/gui/$s")"

read -r summary <<<"$(python3 - "$artifacts/metadata.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(m["project"], m["session"], m["backend"], m["resolution"], m["state"], m["apps"][0]["exit_status"], m["apps"][0]["command"][0],
	m["recording"]["codec"], bool(m["recording"]["stopped_at"]), m["result"]["outcome"], bool(m["screenshots"][0]["at"]), bool(m["stopped_at"]))
PY
)"
eq "metadata describes the session" "alpha agent-run sway-headless 1280x720 stopped 7 python3 h264 True pass True True" "$summary"
eq "the trace holds no typed text" 0 "$(grep -c 'Hello' "$artifacts/inputs.jsonl")"
eq "the trace records the length" 1 "$(grep -c "\"length\": ${#text}" "$artifacts/inputs.jsonl")"
eq "artifacts are private to the project" 600 "$(stat -c %a "$artifacts/metadata.json")"
finish
