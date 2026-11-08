#!/bin/bash
# Chromium is the Electron-class target. Its own sandbox must work inside the project's.
source "$(dirname "$0")/lib.sh"
s=browser
page=/tmp/browser-page.html
cat > "$page" <<'HTML'
<!doctype html><title>waiting</title>
<body style="margin:0;height:100vh;background:#00f" onclick="document.body.style.background='#0f0';document.title='clicked'">
HTML
title() { agentos-gui windows "$s" | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["title"])'; }
probe() { pixel "$(agentos-gui screenshot "$s")" 20 20; }

eq "start" 0 "$(status_of agentos-gui start "$s")"
agentos-gui run "$s" -- chromium --ozone-platform=wayland --no-first-run --disable-gpu \
	--user-data-dir=/tmp/browser-profile "--app=file://$page" >/dev/null
eventually "the page loads" waiting title
eventually "the page paints blue" "0 0 255" probe
eq "click is accepted" 0 "$(status_of agentos-gui click "$s" 640 400)"
eventually "the page received the click" clicked title
eventually "the page repaints green" "0 255 0" probe

renderer=$(pgrep -u "$(id -u)" -f -- '--type=renderer' | head -1)
eq "a renderer process exists" 1 "$(( renderer > 0 ))"
eq "the renderer has its own user namespace" 1 "$(( $(readlink "/proc/$renderer/ns/user" | tr -cd 0-9) != $(readlink /proc/self/ns/user | tr -cd 0-9) ))"
eq "the renderer has its own PID namespace" 1 "$(( $(readlink "/proc/$renderer/ns/pid" | tr -cd 0-9) != $(readlink /proc/self/ns/pid | tr -cd 0-9) ))"
eq "stop" stopped "$(agentos-gui stop "$s")"
finish
