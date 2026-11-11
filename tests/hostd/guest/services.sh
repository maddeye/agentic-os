#!/bin/bash
# The system agent asks hostd for projects that run an administrator's service.
# Then a T3 Code server that the system agent runs links to one of them.
source "$(dirname "$0")/lib.sh"
services=/etc/agent-os/services
t3=/opt/agent-os/toolchains/t3/0.1.8/t3
port=3773

plan 3 toolchain install t3 0.1.8
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
eq "t3 toolchain applies" applied "$(hostctl_ change apply "$id" | field state)"

# The administrator's service. A request can name it and nothing more.
install -d -m 0755 "$services/t3code"
cat > "$services/t3code/setup" <<'SH'
#!/bin/sh
set -e
mkdir -p "$HOME/.t3/userdata"
echo '{"linkedEnvironmentsEnabled":true}' > "$HOME/.t3/userdata/settings.json"
SH
cat > "$services/t3code/start" <<SH
#!/bin/sh
exec $t3 serve --host 0.0.0.0 --port $port --no-browser .
SH
cat > "$services/t3code/credential" <<SH
#!/bin/sh
exec $t3 auth pairing create --ttl 5m --json
SH
chmod 0755 "$services/t3code/"*

wait_http() { # <url>
	local _
	for _ in $(seq 1 120); do
		[[ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" == 200 ]] && return
		sleep 0.5
	done
}

plan 1 project create x1 --service nope
eq "an unknown service is refused" 1 "$(audited plan_refused unknown_service)"
plan 1 project create ../x --service t3code
plan 1 project create alpha --service t3code
eq "an existing project is refused" 1 "$(audited plan_refused already_exists)"

plan 3 project create hub-a --service t3code
eq "a service off the list waits" "service t3code is not on the automatic list" "$(field decision.reasons.0 <<<"$change")"
agentos system change reject "$(field id <<<"$change")" >/dev/null
eq "a rejected create leaves no project" 2 "$(status_of agentos project inspect hub-a)"

count=$(agentos project list | tail -n +2 | wc -l)
set_policy "{\"automatic_project_services\": [\"t3code\"], \"automatic_project_limit\": $((count + 1))}"
plan 0 project create hub-a --service t3code
eq "a listed service below the limit applies" applied "$(field state <<<"$change")"
eq "the change records its undo" "agentos project delete hub-a --yes" "$(field outcome.recovery <<<"$change")"
eq "the project records its service" 1 "$(agentos project inspect hub-a | grep -c '^service=t3code$')"
address=$(agentos project inspect hub-a | sed -n 's/^address=//p')
wait_http "http://$address:$port/"
eq "the service answers on the project address" 200 "$(curl -s -o /dev/null -w '%{http_code}' "http://$address:$port/")"
eq "the service runs as the project" "$(id -u aos-hub-a)" "$(ps -o uid= -p "$(systemctl show -P MainPID "aos-svc-$(id -u aos-hub-a).service")" | tr -d ' ')"

plan 3 project create hub-b --service t3code
eq "the limit makes the next create wait" 1 "$(field decision.reasons <<<"$change" | grep -c 'automatic limit')"
agentos system change reject "$(field id <<<"$change")" >/dev/null

# Only projects that hostd created with a service give out credentials.
eq "a project agent cannot ask for a credential" 1 "$(status_of agentos project run alpha -- /usr/sbin/agentos system service credential hub-a)"
eq "a project without a service has no credential" 1 "$(status_of hostctl_ service credential alpha)"
eq "a bad name has no credential" 1 "$(status_of hostctl_ service credential ../hub-a)"
reply=$(hostctl_ service credential hub-a)
eq "the credential names the address" "$address" "$(field address <<<"$reply")"
code=$(field credential <<<"$reply" | field credential)
eq "the credential is a pairing code" 1 "$(grep -cE '^[A-Z0-9]{8,}$' <<<"$code")"
eq "the audit records the credential request" 1 "$(audited service_credential '"project":"hub-a","result":"ok"')"
eq "the audit never holds the credential" 0 "$(grep -c "$code" "$audit")"

eq "a running service is left alone" running "$(hostctl_ service start hub-a | field state)"
agentos project stop hub-a
eq "start brings a stopped service back" started "$(hostctl_ service start hub-a | field state)"
wait_http "http://$address:$port/"
eq "the restarted service answers" 200 "$(curl -s -o /dev/null -w '%{http_code}' "http://$address:$port/")"

# The orchestrator runs as the system agent on the host, which reaches project ports.
# T3 Code sends link credentials over plain http only to loopback, hence the relay.
sys mkdir -p /var/lib/agent-os/system-agent/.t3/userdata
sys sh -c 'echo "{\"linkedEnvironmentsEnabled\":true}" > "$HOME/.t3/userdata/settings.json"'
as_system_unit() { # <unit> <command...>
	local unit=$1
	shift
	systemd-run --quiet --collect --unit="$unit" --uid=agentos-system --gid=agentos-system \
		--setenv=HOME=/var/lib/agent-os/system-agent --working-directory=/var/lib/agent-os/system-agent -- "$@"
}
as_system_unit aos-test-hub "$t3" serve --host 127.0.0.1 --port 37760 --no-browser .
as_system_unit aos-test-relay socat TCP-LISTEN:37761,bind=127.0.0.1,fork,reuseaddr "TCP:$address:$port"
wait_http http://127.0.0.1:37760/
code=$(hostctl_ service credential hub-a | field credential | field credential)
sys timeout 90 "$t3" environment link http://127.0.0.1:37761 --pairing-code "$code" --access full-access 2>&1 | tail -1
eq "the system agent's T3 Code links to the project" 1 "$(sys "$t3" environment list | grep -c '^  reachable')"
systemctl stop aos-test-relay.service aos-test-hub.service

# A killed broker leaves a create that the next request finishes.
install -d -m 0755 "$services/slow"
printf '#!/bin/sh\nwhile [ -e %s ]; do sleep 0.2; done\n' "$services/slow/hold" > "$services/slow/setup"
printf '#!/bin/sh\nexec sleep infinity\n' > "$services/slow/start"
chmod 0755 "$services/slow/setup" "$services/slow/start"
touch "$services/slow/hold"
set_policy "{\"automatic_project_services\": [\"slow\"], \"automatic_project_limit\": 99}"
hostctl_ project create hub-c --service slow "${reason[@]}" >/dev/null 2>&1 &
client=$!
wait_for pgrep -f "$services/slow/setup" >/dev/null
eq "the create reached its setup" 0 "$?"
kill_broker
wait "$client" 2>/dev/null
rm "$services/slow/hold"
wait_for bash -c "! systemctl list-units --no-legend --state=active 'aos-setup-*' | grep -q ."
recovered=$(hostctl_ recover | field recovered)
eq "recovery finds the interrupted create" 1 "$(grep -cE '^\[[0-9]+\]$' <<<"$recovered")"
id=$(tr -d '[]' <<<"$recovered")
eq "recovery finishes the create" applied "$(hostctl_ change show "$id" | field state)"
eq "the finished project runs its service" 0 "$(status_of systemctl is-active --quiet "aos-svc-$(id -u aos-hub-c).service")"

set_policy '{"automatic_project_services": [], "automatic_project_limit": 0}'
agentos project delete hub-a --yes
agentos project delete hub-c --yes
rm -rf "$services/t3code" "$services/slow"
finish
