#!/bin/bash
source "$(dirname "$0")/lib.sh"
systemctl stop agentos-storage.timer
root=$projects/alpha
for n in 1 2 3; do agentos project snapshot alpha --auto --label "a$n" >/dev/null; done
manual=$(snapshot_count alpha)
before=$(kinds alpha)

# Free space is integer percent and always below 100, so these settings force each state.
sed -i 's/^reserve_percent=.*/reserve_percent=100/' "$conf"
sed -i 's/^critical_percent=.*/critical_percent=0/' "$conf"
eq "snapshot refused without the reserve" 2 "$(status_of agentos project snapshot alpha)"
agentos storage check >/dev/null
eq "pressure keeps one automatic snapshot" 1 "$(agentos project snapshots alpha | tail -n +2 | cut -f2 | grep -c auto)"
eq "pressure keeps manual snapshots" "$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^manual=/) print $i}' <<<"$before")" \
	"$(kinds alpha | tr ' ' '\n' | grep manual)"
eq "commands keep running at low pressure" 0 "$(status_of agent alpha -- true)"

agent alpha -- dd if=/dev/urandom of="$root/workspace/largest" bs=1M count=100 status=none
sync
agentos project run --detach alpha -- sleep 600 >/dev/null
agentos project run --detach beta -- sleep 600 >/dev/null
settle
sed -i 's/^critical_percent=.*/critical_percent=100/' "$conf"
output=$(agentos storage check)
[[ "$output" == *"Stopping commands of alpha"* ]] && report ok "critical pressure names the largest project" || report FAIL "critical pressure names the largest project" "$output"
eq "largest project is stopped" 0 "$(agentos project ps alpha | wc -l)"
eq "smaller project keeps running" 1 "$(agentos project ps beta | wc -l)"
eq "stopped project can start again" 0 "$(status_of agent alpha -- true)"
agentos project stop beta
agent alpha -- rm -f "$root/workspace/largest"

sed -i 's/^reserve_percent=.*/reserve_percent=10/' "$conf"
sed -i 's/^critical_percent=.*/critical_percent=5/' "$conf"
[[ "$(agentos storage check)" == "storage: ok,"* ]] && report ok "healthy disk reports ok" || report FAIL "healthy disk reports ok"
eq "bad setting is rejected" 2 "$(status_of bash -c "echo 'reserve_percent=x' >> $conf; agentos project snapshot alpha")"
sed -i '/^reserve_percent=x$/d' "$conf"
systemctl start agentos-storage.timer
sleep 1
finish
