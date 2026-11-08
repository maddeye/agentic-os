# Helpers shared by the hostd steps. Source this file.
source /opt/aos-tests/tests/integration/guest/lib.sh
audit=/var/lib/agent-os/metadata/hostd/audit.jsonl
artifacts=/var/lib/agent-os/metadata/hostd/artifacts

# Runs a command as the system agent, with the identity and nothing else.
sys() { setpriv --reuid=agentos-system --regid=agentos-system --clear-groups --reset-env -- env PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/var/lib/agent-os/system-agent "$@"; }
hostctl_() { sys agentos system "$@"; }
reason=(--reason "phase 2 test")

field() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[k] if not isinstance(v,list) else v[int(k)]
print(json.dumps(v) if isinstance(v,(list,dict)) else v)' "$1"; }

# Leaves the JSON reply in $change.
plan() { # <expected exit> <args for agentos system>
	local expected=$1 rc=0
	shift
	change=$(hostctl_ "$@" "${reason[@]}") || rc=$?
	eq "exit status of system $*" "$expected" "$rc"
}

installed() { [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == "ii " ]]; }
audited() { # <event> <fragment>: counts audit lines with both
	grep -F "\"event\":\"$1\"" "$audit" | grep -cF "$2"
}
set_policy() { # <JSON object of fields to replace>
	python3 - "$1" <<'PY'
import json, sys
path = "/etc/agent-os/hostd-policy.json"
policy = json.load(open(path))
policy.update(json.loads(sys.argv[1]))
json.dump(policy, open(path, "w"))
PY
}
