#!/bin/bash
source "$(dirname "$0")/lib.sh"
eq "workspace data survives reboot" finished "$(cat "$projects/alpha/workspace/after-disconnect")"
eq "project-local tools survive reboot" 1 "$(agentos project run alpha -- node --version | grep -c '^v')"
eq "identity is stable" aos-alpha "$(agentos project run alpha -- id -un)"
eq "projects are still registered" "alpha beta" "$(agentos project list | tail -n +2 | cut -f1 | xargs)"
eq "running commands do not resume" "" "$(agentos project ps alpha)"
eq "network namespace returns after reboot" 0 "$(status_of agentos project run alpha -- curl -fsS -m 20 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release.gpg)"
finish
