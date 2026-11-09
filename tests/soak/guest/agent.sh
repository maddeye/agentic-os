#!/bin/bash
# One unattended project agent. Repeats harness turns until the deadline and records each one in ledger.tsv.
name=$1
deadline=$2

turn=0
while (( $(date +%s) < deadline )); do
	turn=$((turn + 1))
	problems=
	rm -f harness-proof.txt
	output=$(timeout 120 pi -p 'run the tool' --provider stub --model stub-1 --no-session </dev/null 2>&1)
	[[ "$(tail -1 <<<"$output")" == "stub-saw: aos-$name $PWD " ]] || problems+=harness,
	[[ "$(cat harness-proof.txt 2>/dev/null)" == harness-tool-ran ]] || problems+=tool,
	file=data-$((turn % 20))
	head -c 1048576 /dev/urandom > "$file" || problems+=write,
	sum=$(sha256sum "$file" | cut -d' ' -f1)
	printf '%s\t%s\t%s\t%s\t%s\n' "$turn" "$(date +%s)" "${problems:-ok}" "$file" "$sum" >> ledger.tsv
	sleep 5
done
