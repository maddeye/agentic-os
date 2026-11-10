#!/bin/bash
# One minute of an unattended run. Records host state, then acts as the administrator and as a runaway project.
source "$(dirname "$0")/common.sh"
spin="import os, time
for _ in range(2):
    if os.fork() == 0:
        start = time.perf_counter()
        while time.perf_counter() - start < 3: pass
        os._exit(0)
os.wait(); os.wait()
print(int(100 * sum(os.times()[2:4]) / 3))"

# A harness turn adds tasks and memory for a moment, so each sample keeps the quietest of five readings a second apart.
readings=$(for _ in 1 2 3 4 5; do
	printf '%s\t%s\t%s\n' "$(mem_available)" "$(cat "$slice/pids.current")" "$(( $(cat "$slice/memory.current") >> 20 ))"
	sleep 1
done)
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(cut -f1 <<<"$readings" | sort -n | tail -1)" \
	"$(cut -f2 <<<"$readings" | sort -n | head -1)" "$(cut -f3 <<<"$readings" | sort -n | head -1)" "$(data_used)" >> "$state/samples.tsv"

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

eq "allocation under the limit in noisy works" 0 "$(status_of agent noisy -- python3 -c "x = b'\\1' * (256 << 20)")"
eq "memory overrun in noisy fails" 1 "$(status_of agent noisy -- python3 -c "x = b'\\1' * (768 << 20)")"
eq "process count under the limit in noisy works" 0 "$(status_of agent noisy -- python3 -c 'import subprocess; [subprocess.Popen(["sleep", "1"]) for _ in range(50)]')"
eq "process overrun in noisy fails" 1 "$(status_of agent noisy -- python3 -c 'import subprocess; [subprocess.Popen(["sleep", "1"]) for _ in range(200)]')"
between "two spinners in noisy share its CPU quota (%)" 40 130 "$(agent noisy -- python3 -c "$spin")"
eq "SSH service stays active" active "$(systemctl is-active ssh)"
finish
