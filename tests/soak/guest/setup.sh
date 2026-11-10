#!/bin/bash
# Creates the projects, installs a harness in each, records an idle baseline, and starts the agents.
source "$(dirname "$0")/common.sh"
here=$(dirname "$0")
source "$here/../../integration/versions.env"
duration=$1
guest=/opt/aos-tests/tests

mkdir -p "$state"
node_dir=node-$NODE_VERSION-linux-x64
for name in "${steady[@]}"; do
	agentos project create "$name" >/dev/null
	agent "$name" -- bash -euc "
		mkdir -p ~/.local/bin ~/.local/lib ~/.pi/agent
		cd /tmp
		curl -fsSLO https://nodejs.org/dist/$NODE_VERSION/$node_dir.tar.xz
		echo '$NODE_SHA256  $node_dir.tar.xz' | sha256sum -c --quiet
		tar -C ~/.local/lib -xJf $node_dir.tar.xz
		rm $node_dir.tar.xz
		ln -sf ../lib/$node_dir/bin/node ../lib/$node_dir/bin/npm -t ~/.local/bin
		npm install --global --silent --prefix ~/.local '@earendil-works/pi-coding-agent@$PI_VERSION'
	" 2>&1 | tee "$state/$name.install.log" | tail -3
	agent "$name" -- bash -c 'cat > ~/.pi/agent/models.json' <<'JSON'
{"providers":{"stub":{"baseUrl":"http://127.0.0.1:18080/v1","api":"openai-completions","apiKey":"not-a-secret","models":[{"id":"stub-1"}]}}}
JSON
	agent "$name" -- bash -c 'echo soak > marker'
	eq "$name has the harness" "$PI_VERSION" "$(agent "$name" -- pi --version 2>&1 | tail -1)"
done
agentos project create noisy --cpu 100 --memory-max 512M --tasks 128 >/dev/null

drop_caches
mem_available > "$state/baseline-memory"
data_used > "$state/baseline-disk"

# Workers outlast the ticks by a minute, so the last tick still finds them running.
start=$(date +%s)
deadline=$(( start + duration + 60 ))
echo "$start $deadline" > "$state/window"
for name in "${steady[@]}"; do
	agentos project run --detach "$name" -- /usr/bin/python3 "$guest/integration/guest/stub_model.py" >/dev/null
	agentos project run --detach "$name" -- /bin/bash "$guest/soak/guest/agent.sh" "$name" "$deadline" >/dev/null
done
finish
