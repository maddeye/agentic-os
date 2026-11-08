#!/bin/bash
# Measures software rendering in a project. Runs inside the sandbox.
set -euo pipefail
app=/opt/aos-tests/tests/gui/guest/app.py
seconds=15
ms() { echo $(( $(date +%s%N) / 1000000 )); }
cpu_ticks() { # sums user and system ticks of every project process
	local stat total=0
	for stat in /proc/[0-9]*/stat; do
		[[ -O "$stat" ]] || continue
		read -r -a fields < <(sed 's/.*) //' "$stat" 2>/dev/null) || continue
		(( total += ${fields[11]:-0} + ${fields[12]:-0} ))
	done
	echo "$total"
}

recording() { # <session> <size> <motion label> <app flag>
	local s=$1 size=$2 label=$3 flag=$4 before after frames file
	agentos-gui start "$s" --size "$size"
	agentos-gui run "$s" -- python3 "$app" "$flag" >/dev/null
	agentos-gui wait "$s" --window agentostest
	sleep 1
	agentos-gui record start "$s" >/dev/null
	before=$(cpu_ticks)
	sleep "$seconds"
	after=$(cpu_ticks)
	agentos-gui record stop "$s" >/dev/null
	file=$HOME/../artifacts/gui/$s/recording.mkv
	frames=$(ffprobe -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 "$file")
	echo "$size	$label: CPU percent of one core, whole session	$(( (after - before) * 100 / ($(getconf CLK_TCK) * seconds) ))"
	echo "$size	$label: recorded frames per second, motion at 30	$(( frames / seconds ))"
	echo "$size	$label: recording KiB per minute	$(( $(stat -c %s "$file") * 60 / seconds / 1024 ))"
	agentos-gui stop "$s" >/dev/null
}

measure() { # <session> <size>
	local s=$1 size=$2 t0 before after _
	t0=$(ms)
	agentos-gui start "$s" --size "$size"
	echo "$size	session start ms	$(( $(ms) - t0 ))"

	t0=$(ms)
	agentos-gui run "$s" -- python3 "$app" >/dev/null
	agentos-gui wait "$s" --window agentostest
	echo "$size	GTK window ms	$(( $(ms) - t0 ))"

	sleep 2
	before=$(cpu_ticks)
	sleep 10
	after=$(cpu_ticks)
	echo "$size	idle CPU percent of one core	$(( (after - before) * 100 / ($(getconf CLK_TCK) * 10) ))"
	echo "$size	session RSS MiB	$(ps -u "$(id -u)" -o rss=,args= | grep -E 'sway|wayvnc|dbus-daemon|Xwayland|agentos-gui start' | grep -v grep | awk '{ s += $1 } END { print int(s / 1024) }')"

	t0=$(ms)
	for _ in $(seq 1 20); do agentos-gui screenshot "$s" >/dev/null; done
	echo "$size	screenshot ms	$(( ($(ms) - t0) / 20 ))"
	agentos-gui stop "$s" >/dev/null

	recording "$s-small" "$size" "small motion" --animate
	recording "$s-full" "$size" "full-frame motion" --animate-full
}

printf 'resolution\tmetric\tvalue\n'
measure b720 1280x720
measure b1080 1920x1080
