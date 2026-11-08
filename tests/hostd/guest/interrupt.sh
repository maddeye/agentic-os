#!/bin/bash
# Kills hostd and its dpkg in the middle of a transaction, then recovers.
source "$(dirname "$0")/lib.sh"
root=/opt/agent-os/toolchains

kill_broker() { systemctl kill --kill-whom=all -s KILL 'agentos-hostd@*.service'; }

wait_for() { # <command...>
	local _
	for _ in $(seq 1 600); do "$@" && return 0; sleep 0.1; done
	return 1
}
hanging() { pgrep -f 'aos-test-[a-z]*\.postinst' >/dev/null; }

touch /run/aos-test-hang
plan 3 package install aos-test-hang
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
hostctl_ change apply "$id" >/dev/null 2>&1 &
client=$!
wait_for hanging; eq "transaction reaches the package script" 0 $?
eq "a package script cannot see project data" 1 "$(status_of nsenter -m -t "$(pgrep -f 'aos-test-hang\.postinst' | head -1)" -- test -e "$projects/alpha/home/secret")"
kill_broker
wait "$client" 2>/dev/null
wait_for test -z "$(systemctl list-units --plain --no-legend 'agentos-hostd@*.service' --state=active)"
eq "killing the broker also kills dpkg" 1 "$(status_of hanging)"
eq "package is left unfinished" False "$(hostctl_ status | field dpkg_consistent)"
eq "change is left applying" applying "$(hostctl_ change show "$id" | field state)"
eq "status reports the interrupted change" "[$id]" "$(hostctl_ status | field applying)"

rm /run/aos-test-hang
recovered=$(hostctl_ recover)
eq "recover reports the change" "[$id]" "$(field recovered <<<"$recovered")"
eq "dpkg is consistent again" True "$(hostctl_ status | field dpkg_consistent)"
result=$(hostctl_ change show "$id")
eq "transaction rolls forward" applied "$(field state <<<"$result")"
eq "outcome records the recovery" True "$(field outcome.recovered <<<"$result")"
eq "recovery is audited" 1 "$(audited recovery "\"change\":$id")"
installed aos-test-hang; eq "package is installed" 0 $?
eq "apt works after recovery" 0 "$(status_of apt-get -s install hello)"

# The next request recovers on its own when nobody asks.
touch /run/aos-test-hang
dpkg --purge aos-test-hang >/dev/null
plan 3 package install aos-test-hang
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
hostctl_ change apply "$id" >/dev/null 2>&1 &
client=$!
wait_for hanging
kill_broker
wait "$client" 2>/dev/null
rm /run/aos-test-hang
plan 3 package install hello
agentos system change reject "$(field id <<<"$change")" >/dev/null
eq "a later request repairs the host first" applied "$(hostctl_ change show "$id" | field state)"

# A killed toolchain install leaves nothing half-published.
plan 3 toolchain install node 24.22.2
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
hostctl_ change apply "$id" >/dev/null 2>&1 &
client=$!
staged() { [[ -n "$(ls -A "$root/.staging" 2>/dev/null)" ]]; }
wait_for staged; eq "toolchain reaches staging" 0 $?
kill_broker
wait "$client" 2>/dev/null
eq "killed install is not published" 1 "$(status_of test -e "$root/node/24.22.2")"
hostctl_ recover >/dev/null
eq "killed install ends as failed" failed "$(hostctl_ change show "$id" | field state)"
eq "staging is cleaned" "" "$(ls -A "$root/.staging")"

# A concurrent request waits for the running transaction, and cannot overlap it.
touch /run/aos-test-hang
dpkg --purge aos-test-hang >/dev/null
plan 3 package install aos-test-hang
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
hostctl_ change apply "$id" >/dev/null 2>&1 &
client=$!
wait_for hanging
hostctl_ recover >/dev/null 2>&1 &
second=$!
sleep 3
eq "live transaction is not treated as interrupted" applying "$(hostctl_ change show "$id" | field state)"
hanging; eq "live transaction keeps running" 0 $?
rm /run/aos-test-hang
wait "$client" "$second" 2>/dev/null
eq "transaction finishes normally" applied "$(hostctl_ change show "$id" | field state)"
eq "it was not marked as recovered" False "$(hostctl_ change show "$id" | field outcome.recovered)"

# Stop here with a transaction hanging, so the host runner can cut the power.
touch /run/aos-test-power
plan 3 package install aos-test-power
power_id=$(field id <<<"$change")
agentos system change approve "$power_id" >/dev/null
(hostctl_ change apply "$power_id" >/dev/null 2>&1 &)
wait_for hanging; eq "transaction hangs before the power cut" 0 $?
echo "$power_id" > /root/power-change
sync
finish
