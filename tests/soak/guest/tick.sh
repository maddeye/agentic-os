#!/bin/bash
# One minute of an unattended run. Records host state, then acts as the administrator and as a runaway project.
source "$(dirname "$0")/common.sh"

printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(mem_available)" "$(cat "$slice/pids.current")" \
	"$(( $(cat "$slice/memory.current") >> 20 ))" "$(data_used)" >> "$state/samples.tsv"

for pair in one:two two:three three:one; do
	reader=${pair%:*}
	owner=${pair#*:}
	eq "$reader cannot read the marker of $owner" 1 "$(status_of agent "$reader" -- cat "$projects/$owner/workspace/marker")"
	eq "$owner reads its own marker" 0 "$(status_of agent "$owner" -- cat "$projects/$owner/workspace/marker")"
done

for name in "${steady[@]}"; do
	eq "$name still runs its agent and model" 2 "$(agentos project ps "$name" | wc -l)"
	eq "$name takes a snapshot under load" 0 "$(status_of agentos project snapshot "$name" --auto)"
	eq "$name prunes old snapshots" 0 "$(status_of agentos project prune "$name" --keep 5)"
done

eq "hostd answers" 0 "$(status_of agentos system status)"

eq "memory overrun in noisy fails" 1 "$(status_of agent noisy -- python3 -c "x = b'\\1' * (768 << 20)")"
eq "process overrun in noisy fails" 1 "$(status_of agent noisy -- python3 -c 'import subprocess; [subprocess.Popen(["sleep", "1"]) for _ in range(200)]')"
eq "CPU spin in noisy runs out its time" 124 "$(status_of agent noisy -- timeout 5 sh -c 'while :; do :; done')"
eq "SSH service stays active" active "$(systemctl is-active ssh)"
finish
