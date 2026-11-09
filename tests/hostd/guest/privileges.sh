#!/bin/bash
# Proves who can reach hostd, and what the system agent cannot do.
source "$(dirname "$0")/lib.sh"
agent_uid=$(id -u aos-alpha)
sock=/run/agentos/hostd.sock

# Separation from a project.
eq "project cannot use the client" 1 "$(status_of agentos project run alpha -- /usr/sbin/agentos system status)"
eq "project cannot see the socket" 1 "$(status_of agentos project run alpha -- test -e "$sock")"

# A caller that passes the socket's group check still has the wrong UID.
through_group() { setpriv --reuid="$agent_uid" --regid=agentos-system --clear-groups -- "$@"; }
before=$(audited denied "\"uid\":$agent_uid")
eq "project UID with the socket group is refused" 1 "$(status_of through_group /usr/sbin/agentos-hostctl status)"
eq "the refusal comes from hostd" 1 "$(through_group /usr/sbin/agentos-hostctl status 2>&1 | grep -c '^agentos: denied')"
eq "the refused attempt is audited" 1 "$(( $(audited denied "\"uid\":$agent_uid") > before ))"
forged='{"request":"change_approve","id":1,"caller":{"uid":0}}'
eq "forged identity is rejected as malformed" malformed "$(sys python3 /opt/aos-tests/tests/hostd/guest/send.py "$forged" | field code)"
eq "project cannot apply through the group" 1 "$(status_of through_group /usr/sbin/agentos-hostctl change apply 1)"

# The contract has no general command.
for body in '{"request":"run_as_root","command":"id"}' 'not json' '' '{"request":"change_plan","reason":"x","operation":{"type":"shell","command":"id"}}'; do
	eq "malformed: ${body:0:30}" malformed "$(sys python3 /opt/aos-tests/tests/hostd/guest/send.py "$body" | field code)"
done
# hostd closes with unread input, so the kernel resets the client before it reads the reply.
before=$(audited malformed_request '"result":"malformed"')
sys python3 -c 'import socket; s = socket.socket(socket.AF_UNIX); s.connect("/run/agentos/hostd.sock"); s.sendall(b"x" * 70000 + b"\n"); s.recv(100)' 2>/dev/null
eq "oversized request is rejected" 1 "$(( $(audited malformed_request '"result":"malformed"') == before + 1 ))"
# One time limit covers the whole request, however slowly its bytes arrive.
elapsed=$(sys python3 - <<'PY'
import select, socket, time
s = socket.socket(socket.AF_UNIX); s.connect("/run/agentos/hostd.sock")
start = time.monotonic()
try:
    while time.monotonic() - start < 30 and not select.select([s], [], [], 2)[0]:
        s.sendall(b"x")
except OSError:
    pass
print(int(time.monotonic() - start))
PY
)
between "a drip-feeding client is cut off" 8 13 "$elapsed"

# The system agent can fill its own socket, and the administrator's stays free.
sys python3 - <<'PY' &
import socket, time
held = [socket.socket(socket.AF_UNIX) for _ in range(16)]
for s in held:
    s.connect("/run/agentos/hostd.sock")
    s.sendall(b"x")
time.sleep(9)
PY
holder=$!
sleep 1
eq "16 held connections fill the system agent socket" 1 "$(status_of hostctl_ status)"
eq "the administrator still gets through" 0 "$(status_of timeout 3 agentos system status)"
wait "$holder"
sleep 3
eq "the system agent gets back in once they close" 0 "$(status_of hostctl_ status)"

# The system agent has no route to root or to project data.
eq "system agent has no sudo" 1 "$(status_of sys sudo -n true)"
eq "system agent cannot run project commands" 1 "$(status_of sys agentos project list)"
eq "system agent cannot read project files" 1 "$(status_of sys cat "$projects/alpha/home/secret")"
eq "system agent cannot list projects" 2 "$(status_of sys ls "$projects")"
eq "system agent cannot write /usr" 1 "$(status_of sys touch /usr/bin/.aos-probe)"
eq "system agent cannot write toolchains" 1 "$(status_of sys touch /opt/agent-os/toolchains/.aos-probe)"
eq "system agent cannot read change records" 1 "$(status_of sys cat "$audit")"
eq "system agent cannot edit the policy" 1 "$(status_of sys touch /etc/agent-os/hostd-policy.json)"
eq "system agent cannot use dpkg directly" 2 "$(status_of sys dpkg -i /opt/aos-test-repo/aos-test-clean_1.0_all.deb)"
eq "system agent is not root" agentos-system "$(sys id -un)"
eq "system agent has no extra groups" "agentos-system" "$(sys id -Gn)"
eq "system agent can write its home" 0 "$(status_of sys touch /var/lib/agent-os/system-agent/x)"

eq "no broker runs while idle" "" "$(systemctl list-units --plain --no-legend 'agentos-hostd@*.service' --state=running)"
finish
