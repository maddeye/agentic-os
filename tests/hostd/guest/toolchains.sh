#!/bin/bash
# Installs two versions of one toolchain and gives one to each project.
source "$(dirname "$0")/lib.sh"
root=/opt/agent-os/toolchains
catalog=/usr/share/agent-os/toolchains.json
install_toolchain() { # <version>
	plan 3 toolchain install node "$1"
	local id
	id=$(field id <<<"$change")
	agentos system change approve "$id" >/dev/null
	applied=$(hostctl_ change apply "$id")
	eq "node $1 applies" applied "$(field state <<<"$applied")"
}
install_toolchain 26.13.0
install_toolchain 24.22.2
eq "status lists both versions" '[["node", "24.22.2"], ["node", "26.13.0"]]' "$(hostctl_ status | field toolchains)"
eq "reinstall is refused" 1 "$(status_of hostctl_ toolchain install node 26.13.0 "${reason[@]}")"
eq "toolchain is owned by root" "root:root 755" "$(stat -c '%U:%G %a' "$root/node/26.13.0/bin")"
eq "no file is project-writable" "" "$(find "$root/node" -not -type l -perm /022 | head -1)"
eq "no staging remains" "" "$(ls -A "$root/.staging")"

# Each project chooses independently, and a toolchain is never on PATH by default.
eq "no selection means no node" 127 "$(status_of agentos project run alpha -- node --version)"
agentos project toolchain alpha node 26.13.0
agentos project toolchain beta node 24.22.2
eq "alpha uses 26" v26.13.0 "$(agentos project run alpha -- node --version)"
eq "beta uses 24" v24.22.2 "$(agentos project run beta -- node --version)"
eq "project-local tools still win" "$projects/alpha/home/.local/bin" "$(agentos project run alpha -- bash -c 'echo ${PATH%%:*}')"
eq "inspect shows the selection" 1 "$(agentos project inspect alpha | grep -c '^toolchain.node=26.13.0$')"
eq "unknown version cannot be selected" 2 "$(status_of agentos project toolchain alpha node 1.2.3)"
eq "traversal cannot be selected" 2 "$(status_of agentos project toolchain alpha node 26/../..)"

# Read-only inside the project sandbox.
eq "project cannot write the toolchain" 1 "$(status_of agentos project run alpha -- touch "$root/node/26.13.0/bin/x")"
eq "project cannot replace the runtime" 1 "$(status_of agentos project run alpha -- cp /usr/bin/true "$root/node/26.13.0/bin/node")"
eq "project can run npm from the toolchain" 1 "$(agentos project run alpha -- npm --version | grep -c '^[0-9]')"

# Only catalog entries with the right digest are ever published.
eq "unknown toolchain is refused" 1 "$(status_of hostctl_ toolchain install node 9.9.9 "${reason[@]}")"
eq "unknown tool is refused" 1 "$(status_of hostctl_ toolchain install evil 1.0 "${reason[@]}")"
eq "traversing name is refused" 1 "$(status_of hostctl_ toolchain install ../../etc 1.0 "${reason[@]}")"
python3 - "$catalog" <<'PY'
import json, sys
path = sys.argv[1]
catalog = json.load(open(path))
bad = dict(catalog["toolchains"][1], version="26.0.0-badsum", sha256="0" * 64)
wrong = dict(catalog["toolchains"][1], version="26.0.0-badcheck", check_stdout="v0")
catalog["toolchains"] += [bad, wrong]
json.dump(catalog, open(path, "w"))
PY
for version in 26.0.0-badsum 26.0.0-badcheck; do
	plan 3 toolchain install node "$version"
	id=$(field id <<<"$change")
	agentos system change approve "$id" >/dev/null
	eq "$version fails" 1 "$(status_of hostctl_ change apply "$id")"
	eq "$version is marked failed" failed "$(hostctl_ change show "$id" | field state)"
	eq "$version was not published" 1 "$(status_of test -e "$root/node/$version")"
	eq "$version left no staging" "" "$(ls -A "$root/.staging")"
done

# Removal reports who is affected, and a missing toolchain fails loudly.
plan 3 toolchain remove node 24.22.2
id=$(field id <<<"$change")
eq "removal names affected projects" '["beta"]' "$(field impact.used_by_projects <<<"$change")"
agentos system change approve "$id" >/dev/null
hostctl_ change apply "$id" >/dev/null
eq "toolchain is gone" 1 "$(status_of test -e "$root/node/24.22.2")"
eq "other version is untouched" v26.13.0 "$(agentos project run alpha -- node --version)"
eq "a project on a removed toolchain gets an error" 2 "$(status_of agentos project run beta -- true)"
agentos project toolchain beta node --clear
eq "clearing restores the project" 0 "$(status_of agentos project run beta -- true)"
finish
