#!/bin/bash
# Runs every row of checks.tsv under each execution mode. Runs inside the VM as root.
set -euo pipefail
guest=/opt/aos-tests/tests/isolation/guest
base=/opt/aos-tests
projects=/var/lib/agent-os/projects
export ALPHA_ROOT=$projects/alpha VICTIM_ROOT=$projects/beta
export CONNECT="/usr/bin/python3 $guest/connect.py"
transcript=/var/log/aos-isolation-transcript.log
: > "$transcript"

agentos project create alpha --memory-max 512M --tasks 128 >/dev/null
agentos project create beta --memory-max 512M --tasks 128 >/dev/null
victim_uid=$(id -u aos-beta)

# Root-owned targets for the host-protection rows.
echo secret > /var/lib/agent-os/metadata/secret
echo marker > /opt/agent-os/toolchains/marker
install -o root -g root -m 4755 /usr/bin/id /usr/local/bin/aos-suid-id
cat > /etc/systemd/system/aos-canary.service <<UNIT
[Service]
Type=oneshot
ExecStart=/usr/bin/true
UNIT
systemctl daemon-reload

# Exit status: 0 is open. Shell misuse (2), timeout (124), exec failure (126, 127),
# and systemd setup failure (200 or above) are errors, so they cannot pass as blocked.
classify() {
	case "$1" in
		0) echo open ;;
		2|124|126|127) echo error ;;
		*) if (( $1 >= 200 )); then echo error; else echo blocked; fi ;;
	esac
}

status_of() { local rc=0; "$@" >>"$transcript" 2>&1 || rc=$?; echo "[exit $rc]" >>"$transcript"; classify "$rc"; }

attack() { # <mode> <command>
	local vars=("ALPHA_ROOT=$ALPHA_ROOT" "VICTIM_ROOT=$VICTIM_ROOT" "CONNECT=$CONNECT" "VICTIM_PID=$VICTIM_PID")
	if [[ "$1" == restricted ]]; then
		timeout 60 agentos project run alpha -- "${vars[@]}" /bin/bash -c "$2" </dev/null
	else
		timeout 60 systemd-run --expand-environment=no --wait --pipe --collect --quiet \
			--uid=aos-alpha --gid=aos-alpha -- /usr/bin/env -- "${vars[@]}" /bin/bash -c "$2" </dev/null
	fi
}

control() { # <victim|root|-> <command>
	case "$1" in
		victim) timeout 60 nsenter -t "$VICTIM_PID" -m -i -n -S "$victim_uid" -G "$victim_uid" -- /bin/bash -c "$2" </dev/null ;;
		root) timeout 60 /bin/bash -c "$2" </dev/null ;;
	esac
}

failures=0
printf 'mode\tid\tinvariant\texpected\tactual\tcontrol\tverdict\n'
for mode in plain restricted; do
	rm -f "$VICTIM_ROOT/state/ready"
	if [[ "$mode" == restricted ]]; then
		unit=aos-run-$victim_uid-$(agentos project run --detach beta -- "VICTIM_ROOT=$VICTIM_ROOT" /usr/bin/python3 "$guest/holder.py")
	else
		unit=aos-holder-plain
		systemd-run --quiet --unit="$unit" --collect --uid=aos-beta --gid=aos-beta -E VICTIM_ROOT \
			-- /usr/bin/python3 "$guest/holder.py"
	fi
	for _ in $(seq 1 50); do [[ -e "$VICTIM_ROOT/state/ready" ]] && break; sleep 0.1; done
	[[ -e "$VICTIM_ROOT/state/ready" ]] || { journalctl -u "$unit" --no-pager >&2; exit 2; }
	export VICTIM_PID
	VICTIM_PID=$(systemctl show -P MainPID "$unit")

	while IFS=$'\t' read -r id invariant ctl plain restricted command; do
		[[ -z "$id" || "$id" == \#* ]] && continue
		expected=$plain
		[[ "$mode" == restricted ]] && expected=$restricted
		# A gap is an accepted hole, so the attack still has to succeed.
		want=$expected
		[[ "$want" == gap ]] && want=open
		echo "=== $mode $id" >>"$transcript"
		ctl_result=-
		[[ "$ctl" == - ]] || ctl_result=$(status_of control "$ctl" "$command")
		actual=$(status_of attack "$mode" "$command")
		verdict=pass
		if [[ "$actual" != "$want" || ( "$ctl" != - && "$ctl_result" != open ) ]]; then
			verdict=FAIL
			failures=$((failures + 1))
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$id" "$invariant" "$expected" "$actual" "$ctl_result" "$verdict"
	done < "$base/tests/isolation/checks.tsv"
	systemctl stop "$unit"
	ipcrm --all=shm 2>/dev/null || true
	rm -f /dev/mqueue/beta-q /tmp/beta-world /var/tmp/beta-world /dev/shm/beta-world
done
echo "failures=$failures" >&2
(( failures == 0 ))
