#!/bin/bash
# The Phase 2 exit criterion, and every way around the approval path.
source "$(dirname "$0")/lib.sh"

# The approved route: request, human approval, apply, visible to every project.
! installed ripgrep; eq "ripgrep starts absent" 0 $?
plan 3 package install ripgrep
id=$(field id <<<"$change")
eq "unlisted package waits for approval" awaiting_approval "$(field state <<<"$change")"
eq "impact names the package" ripgrep "$(field impact.actions.0.target <<<"$change")"
eq "impact counts the download" 1 "$(( $(field impact.download_bytes <<<"$change") > 100000 ))"
! installed ripgrep; eq "planning installs nothing" 0 $?

eq "applying before approval is refused" 1 "$(status_of hostctl_ change apply "$id")"
eq "system agent cannot approve itself" 1 "$(status_of hostctl_ change approve "$id")"
eq "self-approval is audited as denied" 1 "$(audited denied "\"change_approve\"")"
eq "change still waits after the attempts" awaiting_approval "$(hostctl_ change show "$id" | field state)"
eq "administrator can approve" 0 "$(status_of agentos system change approve "$id")"
applied=$(hostctl_ change apply "$id")
eq "approved change applies" applied "$(field state <<<"$applied")"
eq "apply is verified" True "$(field outcome.verified <<<"$applied")"
eq "outcome names how to undo it" "agentos system package remove ripgrep" "$(field outcome.recovery <<<"$applied")"
installed ripgrep; eq "ripgrep is installed" 0 $?
eq "an applied change cannot run twice" 1 "$(status_of hostctl_ change apply "$id")"
for project in alpha beta; do
	eq "$project can run ripgrep" 1 "$(agentos project run "$project" -- rg --version | grep -c '^ripgrep ')"
done
eq "projects get the same binary" "$(agentos project run alpha -- bash -c 'command -v rg')" "$(agentos project run beta -- bash -c 'command -v rg')"

# Each audit entry says who, what, the decision, and the result.
eq "plan is audited with caller" 1 "$(audited planned '"name":"agentos-system"' | grep -c '^[1-9]')"
eq "plan is audited with the decision" 1 "$(grep '"event":"planned"' "$audit" | head -1 | grep -c '"level":"approval_required"')"
eq "approval is audited with the administrator" 1 "$(grep '"event":"approved"' "$audit" | head -1 | grep -c '"uid":0')"
eq "result is audited" 1 "$(grep '"event":"finished"' "$audit" | head -1 | grep -c '"verified":true')"
eq "each step is recorded in order" "planning planned apply_refused approved applying finished apply_refused" "$(python3 - "$audit" <<'PY'
import json, sys
print(" ".join(e["event"] for e in map(json.loads, open(sys.argv[1])) if e.get("change") == 1))
PY
)"
eq "audit is root-only" 600 "$(stat -c %a "$audit")"
eq "history is readable through hostd" 1 "$(( $(hostctl_ change history | field 0.time | wc -l) ))"

# A rejected change stays rejected.
plan 3 package install hello
id=$(field id <<<"$change")
agentos system change reject "$id" >/dev/null
eq "rejected change cannot apply" 1 "$(status_of hostctl_ change apply "$id")"
! installed hello; eq "rejected package stays absent" 0 $?

# Approval covers one exact transaction.
plan 3 package install jq
id=$(field id <<<"$change")
eq "plan includes dependencies" 1 "$(field impact.actions <<<"$change" | grep -c libonig5)"
agentos system change approve "$id" >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends libonig5 >/dev/null 2>&1
eq "changed transaction is refused" 1 "$(status_of hostctl_ change apply "$id")"
eq "the change is marked stale" stale "$(hostctl_ change show "$id" | field state)"
! installed jq; eq "stale change installs nothing" 0 $?

# Approval pins the archive. A repository can republish the same version.
source "$(dirname "$0")/debs.sh"
plan 3 package install aos-test-pinned
id=$(field id <<<"$change")
eq "plan records the archive hash" 64 "$(field impact.artifacts.0.sha256 <<<"$change" | tr -d '\n' | wc -c)"
agentos system change approve "$id" >/dev/null
DEB_PAYLOAD=swapped build_deb aos-test-pinned ':'
index_repo
plan 3 package install tree
agentos system change reject "$(field id <<<"$change")" >/dev/null
eq "republished version does not stop the change" applied "$(hostctl_ change apply "$id" | field state)"
eq "the approved bytes are what got installed" payload "$(cat /usr/share/aos-test-pinned/file)"
eq "applied change keeps no archive copy" "" "$(ls -A "$artifacts/$id" 2>/dev/null)"

plan 3 package install aos-test-tamper
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
# A valid archive with the same name and version, so only its hash differs.
DEB_PAYLOAD=tampered DEB_DIR=$artifacts/$id build_deb aos-test-tamper ':'
eq "a changed archive is refused" 1 "$(status_of hostctl_ change apply "$id")"
eq "a changed archive makes the change stale" stale "$(hostctl_ change show "$id" | field state)"
! installed aos-test-tamper; eq "a changed archive installs nothing" 0 $?

# The package that holds the broker. A human decides, and a live project still refuses.
plan 3 package remove agentos
id=$(field id <<<"$change")
eq "removing the broker package is flagged as protected" 1 "$(field decision.reasons <<<"$change" | grep -c 'agentos is a protected package')"
agentos system change approve "$id" >/dev/null
eq "an approved removal fails while projects exist" 1 "$(status_of hostctl_ change apply "$id")"
eq "the broker stays installed" 0 "$(status_of test -x /usr/sbin/agentos-hostd)"
eq "the broker stays reachable" 0 "$(status_of hostctl_ status)"
eq "the failed removal leaves dpkg consistent" True "$(hostctl_ status | field dpkg_consistent)"

# Policy can allow a clean install, and only that.
set_policy '{"automatic_packages":["hello","aos-test-service","aos-test-setuid","apt-utils","aos-test-clean","aos-test-path"]}'
plan 0 package install hello
eq "allowlisted package applies without approval" applied "$(field state <<<"$change")"
eq "policy is recorded as the approver" policy "$(field approved_by <<<"$change")"
installed hello; eq "hello is installed" 0 $?
plan 3 package install aos-test-service
eq "a package with a systemd unit needs approval" 1 "$(field decision.reasons <<<"$change" | grep -c 'aos-test-svc.service')"
plan 3 package install aos-test-path
eq "any unit type needs approval" 1 "$(field decision.reasons <<<"$change" | grep -c 'aos-test-x.path')"
agentos system change reject "$(field id <<<"$change")" >/dev/null
plan 3 package install aos-test-setuid
eq "a package with a setuid file needs approval" 1 "$(field decision.reasons <<<"$change" | grep -c 'helper')"
agentos system change reject "$(field id <<<"$change")" >/dev/null
set_policy '{"protected_package_prefixes":["aos-test-clean"]}'
plan 3 package install aos-test-clean
eq "a protected package needs approval even when listed" 1 "$(field decision.reasons <<<"$change" | grep -c 'protected')"
set_policy '{"automatic_packages":[],"protected_package_prefixes":["linux-"]}'

# Removal.
plan 3 package remove hello
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
hostctl_ change apply "$id" >/dev/null
! installed hello; eq "approved removal removes" 0 $?
eq "essential packages are refused" 1 "$(status_of hostctl_ package remove dpkg "${reason[@]}")"
eq "essential refusal is audited" 1 "$(audited plan_refused '"result":"denied"')"
installed dpkg; eq "dpkg is still installed" 0 $?

# Failed package scripts end as failed, and the host stays usable after repair.
plan 3 package install aos-test-fails
id=$(field id <<<"$change")
agentos system change approve "$id" >/dev/null
eq "failed script fails the change" 1 "$(status_of hostctl_ change apply "$id")"
eq "the change is marked failed" failed "$(hostctl_ change show "$id" | field state)"
eq "the failure is not reported as verified" False "$(hostctl_ change show "$id" | field outcome.verified)"
eq "status reports the unfinished package" False "$(hostctl_ status | field dpkg_consistent)"
dpkg --purge aos-test-fails >/dev/null 2>&1
eq "status clears after cleanup" True "$(hostctl_ status | field dpkg_consistent)"

# A failed upgrade leaves dpkg clean and the old version installed. It still failed.
plan 3 package install aos-test-upgrade
id=$(field id <<<"$change")
eq "the plan shows an upgrade" upgrade "$(field impact.actions.0.kind <<<"$change")"
agentos system change approve "$id" >/dev/null
eq "failed upgrade fails the change" 1 "$(status_of hostctl_ change apply "$id")"
eq "failed upgrade is marked failed" failed "$(hostctl_ change show "$id" | field state)"
eq "old version stays installed" 1.0 "$(dpkg-query -W -f='${Version}' aos-test-upgrade)"
eq "dpkg itself reports no problem" True "$(hostctl_ status | field dpkg_consistent)"

# Without an audit record, no privileged work starts.
chattr +i "$audit"
eq "plan stops when audit cannot be written" 1 "$(status_of hostctl_ package install cowsay "${reason[@]}")"
chattr -i "$audit"
eq "no download happened without a record" 0 "$(find /var/cache/apt/archives -name 'cowsay_*' | wc -l)"

# Hostile names reach apt only if they survive validation, and nothing changes.
before=$(dpkg-query -W | sha256sum)
for bad in '-oDebug::x=1' '../evil' 'x/y.deb' 'ripgrep;id' 'foo*' 'jq=1.0' 'hello:i386' 'hello bar'; do
	eq "name is refused: $bad" 1 "$(status_of hostctl_ package install "$bad" "${reason[@]}")"
done
# These pass the character check, and apt would act on something else.
eq "name-suffix removal is refused" 1 "$(status_of hostctl_ package install ripgrep- "${reason[@]}")"
eq "regex is refused" 1 "$(status_of hostctl_ package install 'ripgre.' "${reason[@]}")"
eq "unknown package is refused" 1 "$(status_of hostctl_ package install no-such-package-x "${reason[@]}")"
eq "hostile names changed nothing" "$before" "$(dpkg-query -W | sha256sum)"
finish
