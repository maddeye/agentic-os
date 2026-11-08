#!/bin/bash
# Installs a toolchain and a coding harness inside a project, without root.
source "$(dirname "$0")/lib.sh"
here=$(dirname "$0")
source "$here/../versions.env"
agent() { agentos project run "$@"; }
packages_before=$(dpkg-query -W | sha256sum)

node_dir=node-$NODE_VERSION-linux-x64
agent alpha -- bash -euc "
	mkdir -p ~/.local/bin ~/.local/lib
	cd /tmp
	curl -fsSLO https://nodejs.org/dist/$NODE_VERSION/$node_dir.tar.xz
	echo '$NODE_SHA256  $node_dir.tar.xz' | sha256sum -c --quiet
	tar -C ~/.local/lib -xJf $node_dir.tar.xz
	rm $node_dir.tar.xz
	ln -sf ../lib/$node_dir/bin/node ../lib/$node_dir/bin/npm -t ~/.local/bin
"
eq "project installs Node without root" "$NODE_VERSION" "$(agent alpha -- node --version)"
eq "node stays private to alpha" 127 "$(status_of agent beta -- node --version)"
eq "node is not on the host" "" "$(command -v node)"

agent alpha -- bash -c 'npm install --global --silent --prefix ~/.local "@earendil-works/pi-coding-agent@'"$PI_VERSION"'"' 2>&1 | tail -3
eq "project installs harness without root" "$PI_VERSION" "$(agent alpha -- pi --version 2>&1 | tail -1)"
eq "host packages are unchanged" "$packages_before" "$(dpkg-query -W | sha256sum)"

stub=$(agentos project run --detach alpha -- /usr/bin/python3 /opt/aos-tests/tests/integration/guest/stub_model.py)
sleep 1
agent alpha -- bash -c 'mkdir -p ~/.pi/agent; cat > ~/.pi/agent/models.json' <<'JSON'
{"providers":{"stub":{"baseUrl":"http://127.0.0.1:18080/v1","api":"openai-completions","apiKey":"not-a-secret","models":[{"id":"stub-1"}]}}}
JSON
output=$(timeout 120 agentos project run alpha -- pi -p 'run the tool' --provider stub --model stub-1 --no-session </dev/null 2>&1)
echo "$output" | tail -5
eq "harness returns the tool result" "stub-saw: aos-alpha $projects/alpha/workspace " "$(tail -1 <<<"$output")"
eq "harness tool wrote the workspace" harness-tool-ran "$(cat "$projects/alpha/workspace/harness-proof.txt")"
eq "harness output belongs to the project" aos-alpha "$(stat -c %U "$projects/alpha/workspace/harness-proof.txt")"
agentos project stop alpha "$stub"
finish
