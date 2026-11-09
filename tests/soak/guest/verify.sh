#!/bin/bash
# Checks a finished unattended run: the work happened, its data is intact, and nothing stayed behind.
source "$(dirname "$0")/common.sh"
duration=$1

for _ in $(seq 1 120); do
	running=0
	for name in "${steady[@]}"; do running=$(( running + $(agentos project ps "$name" | wc -l) )); done
	(( running == ${#steady[@]} )) && break
	sleep 2
done
eq "every agent finished and only the models remain" "${#steady[@]}" "$running"

disk_after=$(data_used)
for name in "${steady[@]}"; do
	ledger=$state/$name.ledger
	agent "$name" -- cat ledger.tsv > "$ledger"
	turns=$(wc -l < "$ledger")
	between "$name completes a turn each minute" "$(( duration / 60 ))" 1000000 "$turns"
	eq "$name turns without a problem" "$turns" "$(awk -F'\t' '$3 == "ok"' "$ledger" | wc -l)"
	eq "$name files match the ledger" 0 "$(status_of agent "$name" -- bash -c \
		"awk -F'\t' '{s[\$4] = \$5} END {for (f in s) print s[f] \"  \" f}' ledger.tsv | sha256sum -c --quiet")"
	eq "$name keeps five snapshots" 5 "$(agentos project snapshots "$name" | awk -F'\t' '$2 == "auto"' | wc -l)"

	agentos project stop "$name"
	oldest=$(agentos project snapshots "$name" | awk -F'\t' '$2 == "auto" {print $3 "\t" $1}' | sort | head -1 | cut -f2)
	agentos project restore "$name" --snapshot "$oldest" --yes >/dev/null
	agent "$name" -- cat ledger.tsv > "$ledger.restored"
	size=$(stat -c %s "$ledger.restored")
	between "$name snapshot holds part of the run" 1 "$(( $(stat -c %s "$ledger") - 1 ))" "$size"
	eq "$name snapshot is an earlier ledger" 0 "$(status_of cmp -n "$size" "$ledger" "$ledger.restored")"
	eq "$name snapshot ledger ends on a whole line" "" "$(tail -c1 "$ledger.restored")"
done

eq "no project task remains" 0 "$(cat "$slice/pids.current")"
eq "no broker process remains" 0 "$(pgrep -c -x agentos-hostd)"

third=$(( $(wc -l < "$state/samples.tsv") / 3 ))
early=$(head -n "$third" "$state/samples.tsv" | cut -f3 | sort -n | tail -1)
late=$(tail -n "$third" "$state/samples.tsv" | cut -f3 | sort -n | tail -1)
between "agents ran during the run (tasks)" 3 16384 "$early"
between "task count did not grow" 0 $(( early + 40 )) "$late"
between "retention bounds disk growth (MiB)" 0 2048 "$(( disk_after - $(cat "$state/baseline-disk") ))"

drop_caches
between "memory returned to the baseline (MiB)" $(( $(cat "$state/baseline-memory") - 256 )) 1000000 "$(mem_available)"

journalctl -k -b -o cat > "$state/kernel.log"
noisy_slice=agentos-project-$(id -u aos-noisy).slice
eq "no kernel fault" "" "$(grep -E 'BUG:|Oops:|blocked for more than|BTRFS (error|critical)|segfault' "$state/kernel.log")"
between "the runaway project reached its memory limit" 1 1000000 "$(grep 'oom-kill:' "$state/kernel.log" | grep -c "oom_memcg=.*/$noisy_slice")"
eq "no other project lost a process to memory" "" "$(grep 'oom-kill:' "$state/kernel.log" | grep -v "oom_memcg=.*/$noisy_slice")"
eq "no unit failed" "" "$(systemctl --failed --no-legend --plain)"
eq "SSH service stays active" active "$(systemctl is-active ssh)"

for name in "${steady[@]}" noisy; do agentos project delete "$name" --yes; done
eq "delete leaves no project" "" "$(ls "$projects")"
eq "delete leaves no account" "" "$(getent passwd | grep '^aos-')"
finish
