#!/bin/bash
# Run after lifecycle.sh, which creates alpha and beta as the first two projects.
source "$(dirname "$0")/lib.sh"
agent() { agentos project run "$@"; }
connect="/usr/bin/python3 /opt/aos-tests/tests/isolation/guest/connect.py"

eq "alpha address" address=10.213.0.2 "$(agentos project inspect alpha | grep '^address=')"
eq "beta address" address=10.213.0.6 "$(agentos project inspect beta | grep '^address=')"
eq "alpha sees its own address" "10.213.0.2/30" "$(agent alpha -- ip -4 -o addr show eth0 | awk '{print $4}')"

listener=$(agentos project run --detach beta -- python3 -m http.server --bind 0.0.0.0 45100)
sleep 1
eq "beta reaches its own server on loopback" 0 "$(status_of agent beta -- $connect tcp 45100)"
eq "administrator reaches a project port" 0 "$(status_of $connect tcp 10.213.0.6:45100)"
eq "alpha cannot reach beta's address" 1 "$(status_of agent alpha -- $connect tcp 10.213.0.6:45100)"
eq "alpha cannot reach beta on its own loopback" 1 "$(status_of agent alpha -- $connect tcp 45100)"
eq "alpha cannot reach the host through its gateway" 1 "$(status_of agent alpha -- $connect tcp 10.213.0.1:22)"
agentos project stop beta "$listener"

eq "a host listener is closed to projects" 1 "$(status_of agent alpha -- $connect tcp 10.0.2.15:22)"
eq "projects can resolve names" 0 "$(status_of agent alpha -- getent hosts deb.debian.org)"
eq "projects keep internet access" 0 "$(status_of agent alpha -- curl -fsS -m 20 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release.gpg)"
finish
