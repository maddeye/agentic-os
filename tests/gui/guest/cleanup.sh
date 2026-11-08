#!/bin/bash
# Every way that a session ends leaves no process and an accurate record.
source "$(dirname "$0")/lib.sh"
quiet() { eq "no graphical process remains ($1)" 0 "$(pgrep -c -f '^(sway|wayvnc|wf-recorder|Xwayland|dbus-daemon --session)' || true)"; }

eq "project stop ends the viewing session" 0 "$(status_of agentos project stop alpha)"
eventually "the unit stop records the state" stopped state alpha view
quiet "project stop"

# A session started inside a command ends with that command, so it cannot be orphaned.
agentos project run alpha -- agentos-gui start scoped --size 800x600
eventually "a session ends with its starting command" stopped state alpha scoped
quiet "starting command exited"

# A recording survives the unit stopping underneath it.
gui alpha start rec --size 800x600
gui alpha run rec -- python3 "$app" --animate >/dev/null
gui alpha wait rec --window agentostest
gui alpha record start rec >/dev/null
sleep 2
agentos project stop alpha
eventually "stopping the unit records the state" stopped state alpha rec
eq "the recording is readable afterward" h264 "$(ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "$projects/alpha/artifacts/gui/rec/recording.mkv")"
quiet "recording"

# A killed supervisor takes the compositor with it, and the next command clears the rest.
gui alpha start crash --size 800x600
gui alpha run crash -- python3 "$app" >/dev/null
gui alpha wait crash --window agentostest
pkill -KILL -u aos-alpha -f 'agentos-gui start crash'
eventually "the compositor dies with its supervisor" 0 bash -c "pgrep -c -u aos-alpha -x sway || true"
eq "list marks the session orphaned" 1 "$(gui alpha list | grep -c $'^crash\torphaned\t')"
eq "the runtime directory is cleared" 0 "$(status_of test ! -e "$projects/alpha/tmp/gui/crash")"
eq "a stopped ID is not reused" 1 "$(status_of gui alpha start crash)"
eq "the artifacts can be removed" 0 "$(status_of gui alpha rm crash)"
eq "the ID is free after removal" 0 "$(status_of gui alpha start crash)"
eq "a running session cannot be removed" 1 "$(status_of gui alpha rm crash)"
eq "several sessions run at once" 0 "$(status_of gui alpha start second)"
eq "both sessions are listed as running" 2 "$(gui alpha list | grep -c $'\trunning\t')"

# Root runs every GUI command as the project, so a planted link reaches nothing.
touch /etc/agent-os/canary
ln -s /etc/agent-os "$projects/alpha/artifacts/gui/planted"
ln -s /etc/agent-os "$projects/alpha/tmp/gui/planted"
chown -h aos-alpha: "$projects/alpha/artifacts/gui/planted" "$projects/alpha/tmp/gui/planted"
eq "list survives planted links" 0 "$(status_of gui alpha list)"
gui alpha rm planted >/dev/null 2>&1
eq "a planted link does not reach host files" 0 "$(status_of test -e /etc/agent-os/canary)"

uid=$(id -u aos-alpha)
agentos project delete alpha --yes >/dev/null
eq "delete leaves no process" 0 "$(pgrep -c -U "$uid" || true)"
quiet "delete"
finish
