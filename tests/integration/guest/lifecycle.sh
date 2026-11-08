#!/bin/bash
source "$(dirname "$0")/lib.sh"
agent() { agentos project run "$@"; }

eq "create alpha" alpha "$(agentos project create alpha)"
eq "create beta" beta "$(agentos project create beta)"
eq "hyphenated name" my-app "$(agentos project create my-app)"
eq "duplicate create fails" 2 "$(status_of agentos project create alpha)"

for bad in '' '../etc' 'A' '1a' 'a/b' 'a-' 'a b' '-x' $'a\nb' "$(printf 'a%.0s' {1..29})"; do
	eq "rejects name [$bad]" 2 "$(status_of agentos project create "$bad")"
done
eq "rejected names create nothing" "3" "$(ls "$projects" | wc -l)"
eq "rejects bad size" 2 "$(status_of agentos project create x1 --memory-max '1G; rm')"

alpha_uid=$(id -u aos-alpha)
beta_uid=$(id -u aos-beta)
between "alpha UID in range" 20000 29999 "$alpha_uid"
between "beta UID in range" 20000 29999 "$beta_uid"
eq "identities differ" 1 "$(( alpha_uid != beta_uid ))"
eq "no login shell" /usr/sbin/nologin "$(getent passwd aos-alpha | cut -d: -f7)"

eq "project root ownership" "root:aos-alpha 750" "$(stat -c '%U:%G %a' "$projects/alpha")"
for child in workspace home cache state artifacts tmp; do
	eq "$child ownership" "aos-alpha:aos-alpha 700" "$(stat -c '%U:%G %a' "$projects/alpha/$child")"
done

eq "runs as project user" aos-alpha "$(agent alpha -- id -un)"
eq "runs as beta user" aos-beta "$(agent beta -- id -un)"
eq "working directory" "$projects/alpha/workspace" "$(agent alpha -- pwd)"
eq "home" "$projects/alpha/home" "$(agent alpha -- printenv HOME)"
eq "no extra groups" "aos-alpha" "$(agent alpha -- id -Gn)"
eq "stdin reaches command" hello "$(echo hello | agent alpha -- cat)"
eq "exit status passes through" 7 "$(status_of agent alpha -- bash -c 'exit 7')"
eq "unknown command exits 127" 127 "$(status_of agent alpha -- no-such-command)"
eq "dollar signs reach the command unchanged" '$HOME' "$(agent alpha -- printf '%s' '$HOME')"
eq "arguments keep spaces" "a b" "$(agent alpha -- printf '%s' 'a b')"
eq "unknown project fails" 2 "$(status_of agent nope -- true)"

export AOS_ADMIN_SECRET=leak-me
eq "administrator environment does not leak" 1 "$(status_of agent alpha -- printenv AOS_ADMIN_SECRET)"
unset AOS_ADMIN_SECRET

agent alpha -- bash -c 'echo shared > /tmp/between-commands'
eq "commands in one project share /tmp" shared "$(agent alpha -- cat /tmp/between-commands)"
eq "beta does not see alpha's /tmp" 1 "$(status_of agent beta -- cat /tmp/between-commands)"

shell_output=$(printf 'id -un\nexit\n' | script -qec 'agentos project shell alpha' /dev/null | tr -d '\r')
eq "interactive shell has project identity" 1 "$(grep -c '^aos-alpha$' <<<"$shell_output")"

id=$(agentos project run --detach alpha -- bash -c 'echo from-detached; sleep 30')
sleep 1
eq "ps lists detached command" "$id" "$(agentos project ps alpha)"
eq "ps is per project" "" "$(agentos project ps beta)"
eq "logs show output" from-detached "$(agentos project logs alpha "$id")"
eq "list counts commands" 1 "$(agentos project list | awk -F'\t' '$1=="alpha"{print $3}')"
eq "inspect reports limit" "limit.TasksMax=4096" "$(agentos project inspect alpha | grep '^limit.TasksMax')"
agentos project stop alpha "$id"
eq "stop ends command" "" "$(agentos project ps alpha)"
eq "stop rejects bad id" 2 "$(status_of agentos project stop alpha '../x')"

agentos project delete my-app --yes
pids=()
for n in 1 2 3 4 5 6; do agentos project create "par$n" >/dev/null & pids+=($!); done
wait "${pids[@]}"
eq "parallel creates get distinct UIDs" 6 "$(for n in 1 2 3 4 5 6; do id -u "aos-par$n"; done | sort -u | wc -l)"
for n in 1 2 3 4 5 6; do agentos project delete "par$n" --yes; done

eq "non-root cannot use the CLI" 1 "$(status_of runuser -u nobody -- agentos project list)"
finish
