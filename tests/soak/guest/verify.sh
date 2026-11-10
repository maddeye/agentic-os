#!/bin/bash
# Checks a finished unattended run: the work happened, its data is intact, and nothing stayed behind.
source "$(dirname "$0")/common.sh"
# Failed ticks count too, so a run that failed any check keeps its projects.
failures=$1
read -r start deadline < "$state/window"

# The first sample often catches every project in its first turn at once. Medians ignore the moments when a turn is running.
median() { # <column> <first line> <last line>
	sed -n "$2,$3p" "$state/samples.tsv" | cut -f"$1" | sort -n | awk '{v[NR] = $1} END {print v[int((NR + 1) / 2)]}'
}

only_models_remain() {
	local name
	for name in "${steady[@]}"; do
		[[ $(agentos project ps "$name" | wc -l) == 1 ]] || return 1
	done
}

for _ in $(seq 1 120); do
	only_models_remain && break
	sleep 2
done
for name in "${steady[@]}"; do
	eq "$name agent finished and only its model remains" 1 "$(agentos project ps "$name" | wc -l)"
done

drop_caches
disk_after=$(data_used)
for name in "${steady[@]}"; do
	ledger=$state/$name.ledger
	agent "$name" -- cat ledger.tsv > "$ledger"
	turns=$(wc -l < "$ledger")
	longest=$(awk -F'\t' -v last="$start" -v end="$deadline" \
		'$2 - last > most {most = $2 - last} {last = $2} END {if (end - last > most) most = end - last; print most + 0}' "$ledger")
	between "$name never goes a minute without a turn (seconds)" 0 60 "$longest"
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

samples=$(wc -l < "$state/samples.tsv")
half=$(( samples / 2 ))
early=$(median 3 2 "$half")
between "agents ran during the run (tasks)" 6 16384 "$early"
between "task count did not grow" 0 $(( early + 20 )) "$(median 3 $(( half + 1 )) "$samples")"
between "project memory did not grow (MiB)" 0 $(( $(median 4 2 "$half") + 128 )) "$(median 4 $(( half + 1 )) "$samples")"
between "available memory did not shrink (MiB)" $(( $(median 2 2 "$half") - 256 )) 1000000 "$(median 2 $(( half + 1 )) "$samples")"
between "retention bounds disk growth (MiB)" 0 512 "$(( disk_after - $(cat "$state/baseline-disk") ))"

drop_caches
between "memory returned to the baseline (MiB)" $(( $(cat "$state/baseline-memory") - 256 )) 1000000 "$(mem_available)"

journalctl -k -b -o cat > "$state/kernel.log"
noisy_slice=agentos-project-$(id -u aos-noisy).slice
eq "no kernel fault" "" "$(grep -E 'BUG:|Oops:|blocked for more than|BTRFS (error|critical)|segfault' "$state/kernel.log")"
between "the runaway project reached its memory limit each tick" "$samples" 1000000 "$(grep 'oom-kill:' "$state/kernel.log" | grep -c "oom_memcg=.*/$noisy_slice")"
eq "no other project lost a process to memory" "" "$(grep 'oom-kill:' "$state/kernel.log" | grep -v "oom_memcg=.*/$noisy_slice")"
eq "no unit failed" "" "$(systemctl --failed --no-legend --plain)"
eq "SSH service stays active" active "$(systemctl is-active ssh)"

# A failed run keeps its projects, so `tests/vm/vm ssh` can inspect them.
if (( failures > 0 )); then
	echo "keeping the projects for inspection"
	finish
fi
for name in "${steady[@]}" noisy; do agentos project delete "$name" --yes; done
eq "delete leaves no project" "" "$(ls "$projects")"
eq "delete leaves no account" "" "$(getent passwd | grep '^aos-')"
finish
