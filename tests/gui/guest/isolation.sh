#!/bin/bash
# Two projects use the same session name at once. Neither can reach the other's.
source "$(dirname "$0")/lib.sh"
connect="/usr/bin/python3 /opt/aos-tests/tests/isolation/guest/connect.py"
run_dir=$projects/alpha/tmp/gui/shared

eq "alpha starts a session" 0 "$(status_of gui alpha start shared)"
eq "beta starts a session with the same name" 0 "$(status_of gui beta start shared)"
eq "alpha starts an application" 1 "$(gui alpha run shared -- python3 "$app")"
eq "alpha's window appears" 0 "$(status_of gui alpha wait shared --window agentostest)"
eq "XWayland application starts" 2 "$(gui alpha run shared -- env GDK_BACKEND=x11 python3 "$app")"
eq "XWayland window appears" 0 "$(status_of gui alpha wait shared --window App.py)"

for socket in control.sock viewer.sock wayland-1 bus; do
	eq "owner reaches $socket" 0 "$(status_of agentos project run alpha -- $connect unix "$run_dir/$socket")"
	eq "beta cannot reach $socket" 1 "$(status_of agentos project run beta -- $connect unix "$run_dir/$socket")"
done
sway_socket=$(basename "$(ls "$run_dir"/sway-ipc.*.sock)")
eq "owner reaches the compositor IPC" 0 "$(status_of agentos project run alpha -- $connect unix "$run_dir/$sway_socket")"
eq "beta cannot reach the compositor IPC" 1 "$(status_of agentos project run beta -- $connect unix "$run_dir/$sway_socket")"
eq "plain UID separation also blocks the socket" 1 "$(status_of setpriv --reuid=aos-beta --regid=aos-beta --clear-groups $connect unix "$run_dir/control.sock")"

eq "owner reaches its abstract X11 socket" 0 "$(status_of agentos project run alpha -- $connect abstract /tmp/.X11-unix/X0)"
gui beta run shared -- python3 "$app" >/dev/null
gui beta wait shared --window agentostest
eq "beta reaches only its own X11 display" 0 "$(status_of agentos project run beta -- $connect abstract /tmp/.X11-unix/X0)"
eq "alpha's display number stays private to its network namespace" 0 "$(status_of nsenter --net=/run/netns/aos-"$(id -u aos-alpha)" python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("\0/tmp/.X11-unix/X0")')"

eq "beta cannot read alpha's artifacts" 1 "$(status_of agentos project run beta -- cat "$projects/alpha/artifacts/gui/shared/metadata.json")"
eq "the viewer opens no TCP port for the project" 0 "$(agentos project run alpha -- ss -ltnH | wc -l)"
eq "the viewer opens no TCP port on the host" 0 "$(ss -ltnp | grep -cE 'wayvnc|sway')"

eq "alpha stops its session" stopped "$(gui alpha stop shared)"
eq "beta's session is still running" running "$(state beta shared)"
eq "beta can still capture" 0 "$(status_of gui beta screenshot shared)"
eq "beta's window survives" 1 "$(gui beta windows shared | wc -l)"
eq "beta stops its session" stopped "$(gui beta stop shared)"
finish
