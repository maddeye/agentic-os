# Assertions shared by the integration steps. Source this file.
set -uo pipefail
failures=0
projects=/var/lib/agent-os/projects

report() { # <ok|FAIL> <name> [detail]
	echo "$1: $2${3:+ ($3)}"
	[[ "$1" == ok ]] || failures=$((failures + 1))
}

eq() { # <name> <expected> <actual>
	if [[ "$2" == "$3" ]]; then report ok "$1"; else report FAIL "$1" "expected [$2], got [$3]"; fi
}

between() { # <name> <low> <high> <actual>
	if (( $4 >= $2 && $4 <= $3 )); then report ok "$1" "$4"; else report FAIL "$1" "expected $2..$3, got $4"; fi
}

status_of() { "$@" >/dev/null 2>&1; echo $?; }

finish() {
	(( failures == 0 )) || { echo "failures=$failures"; exit 1; }
}
