#!/bin/bash
# Runs T3 Code as a project's server and drives one Pi turn through it. Then a second
# project runs an orchestrating T3 Code server that links to the first. Run after tools.sh.
source "$(dirname "$0")/lib.sh"
here=$(dirname "$0")
source "$here/../versions.env"
agent() { agentos project run "$@"; }
connect="/usr/bin/python3 /opt/aos-tests/tests/isolation/guest/connect.py"
port=37730
hub_port=37731

# Root fetches the release once, so neither project reads a file that the other wrote.
t3_dir=t3-$T3_VERSION-linux-x64
downloads=/opt/aos-tests/downloads
install -d -m 0755 "$downloads"
curl -fsSL -o "$downloads/$t3_dir.tar.gz" "https://github.com/pingdotgg/t3code/releases/download/v$T3_VERSION/$t3_dir.tar.gz"
echo "$T3_SHA256  $downloads/$t3_dir.tar.gz" | sha256sum -c --quiet
chmod 0644 "$downloads/$t3_dir.tar.gz"

install_t3() { # <project>
	agent "$1" -- bash -euc "
		mkdir -p ~/.local/bin ~/.local/lib ~/.t3/userdata
		tar -C ~/.local/lib -xzf $downloads/$t3_dir.tar.gz
		ln -sf ../lib/$t3_dir/t3 -t ~/.local/bin
		echo '{\"linkedEnvironmentsEnabled\":true,\"providerInstances\":{\"pi\":{\"driver\":\"pi\",\"enabled\":true}}}' > ~/.t3/userdata/settings.json
	"
}

wait_http() { # <url>
	for _ in $(seq 1 120); do
		[[ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" == 200 ]] && return
		sleep 0.5
	done
}

install_t3 alpha
eq "project installs T3 Code without root" "t3 v$T3_VERSION" "$(agent alpha -- t3 --version)"

rm -f "$projects/alpha/workspace/harness-proof.txt"
stub=$(agentos project run --detach alpha -- /usr/bin/python3 /opt/aos-tests/tests/integration/guest/stub_model.py)
server=$(agentos project run --detach alpha -- t3 serve --host 0.0.0.0 --port $port --no-browser .)
wait_http "http://10.213.0.2:$port/"
eq "administrator reaches the T3 Code server" 200 "$(curl -s -o /dev/null -w '%{http_code}' "http://10.213.0.2:$port/")"
eq "another project cannot reach the T3 Code server" 1 "$(status_of agent beta -- $connect tcp 10.213.0.2:$port)"

agent alpha -- t3 project add . | tail -1
output=$(timeout 180 agentos project run alpha -- t3 thread start --provider pi --model stub/stub-1 --wait . 'run the tool' </dev/null 2>&1)
echo "$output" | tail -5
eq "T3 Code returns the tool result" "stub-saw: aos-alpha $projects/alpha/workspace " "$(tail -1 <<<"$output")"
eq "T3 Code's agent wrote the workspace" harness-tool-ran "$(cat "$projects/alpha/workspace/harness-proof.txt" 2>&1)"
eq "agent output belongs to the project" aos-alpha "$(stat -c %U "$projects/alpha/workspace/harness-proof.txt" 2>&1)"
eq "T3 Code state is in the project home" 0 "$(status_of test -s "$projects/alpha/home/.t3/userdata/statev2.sqlite")"

# beta orchestrates: its server links to alpha's, through one `agentos project link`.
install_t3 beta
hub=$(agentos project run --detach beta -- t3 serve --host 0.0.0.0 --port $hub_port --no-browser .)
wait_http "http://10.213.0.6:$hub_port/"
eq "administrator reaches the orchestrator" 200 "$(curl -s -o /dev/null -w '%{http_code}' "http://10.213.0.6:$hub_port/")"
# T3 Code sends link credentials over plain http only to loopback, so beta relays
# a loopback port to alpha's server. Without a project link, the relay reaches nothing.
relay_port=37740
relay=$(agentos project run --detach beta -- socat TCP-LISTEN:$relay_port,bind=127.0.0.1,fork,reuseaddr TCP:10.213.0.2:$port)
pairing_code() { agent alpha -- t3 auth pairing create --ttl 5m --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["credential"])'; }
link_t3() { timeout 90 agentos project run beta -- t3 environment link "http://127.0.0.1:$relay_port" --pairing-code "$1" --access full-access </dev/null; }
refused=$(status_of link_t3 "$(pairing_code)")
eq "the orchestrator cannot link without a project link" 1 "$(( refused != 0 ))"
agentos project link beta alpha $port
link_t3 "$(pairing_code)" 2>&1 | tail -1
eq "the orchestrator links to the project's server" 1 "$(agent beta -- t3 environment list | grep -c '^  reachable')"
agentos project unlink beta alpha $port
eq "unlink cuts the orchestrator off" 0 "$(agent beta -- t3 environment list | grep -c '^  reachable')"

between "the server keeps its agent running" 1 99 "$(pgrep -c -u aos-alpha -x pi)"
agentos project stop beta "$relay"
agentos project stop beta "$hub"
agentos project stop alpha "$server"
agentos project stop alpha "$stub"
eq "stopping the server stops its agents" 0 "$(pgrep -c -u aos-alpha)"
eq "stopping the orchestrator leaves nothing" 0 "$(pgrep -c -u aos-beta)"
finish
