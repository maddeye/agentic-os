#!/bin/bash
# Argument: the id of a detached command whose SSH client was killed.
source "$(dirname "$0")/lib.sh"
id=$1
eq "client id is well formed" 1 "$(grep -cE '^[0-9a-f]{8}$' <<<"$id")"
eq "command runs after the client dies" "$id" "$(agentos project ps alpha)"
for _ in $(seq 1 40); do
	[[ -e "$projects/alpha/workspace/after-disconnect" ]] && break
	sleep 1
done
eq "command finished its work" finished "$(cat "$projects/alpha/workspace/after-disconnect")"
eq "output belongs to the project" aos-alpha "$(stat -c %U "$projects/alpha/workspace/after-disconnect")"
finish
