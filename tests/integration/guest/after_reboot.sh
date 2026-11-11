#!/bin/bash
source "$(dirname "$0")/lib.sh"
eq "workspace data survives reboot" finished "$(cat "$projects/alpha/workspace/after-disconnect")"
eq "project-local tools survive reboot" 1 "$(agentos project run alpha -- node --version | grep -c '^v')"
eq "identity is stable" aos-alpha "$(agentos project run alpha -- id -un)"
eq "projects are still registered" "alpha beta" "$(agentos project list | tail -n +2 | cut -f1 | xargs)"
eq "running commands do not resume" "" "$(agentos project ps alpha)"
eq "network namespace returns after reboot" 0 "$(status_of agentos project run alpha -- curl -fsS -m 20 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release.gpg)"
listener=$(agentos project run --detach beta -- python3 -m http.server --bind 0.0.0.0 45100)
sleep 1
eq "a link survives reboot" 0 "$(status_of agentos project run alpha -- /usr/bin/python3 /opt/aos-tests/tests/isolation/guest/connect.py tcp 10.213.0.6:45100)"
agentos project stop beta "$listener"
finish
