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

# A link opens one port of one project to one other project, and nothing else.
other=$(agentos project run --detach beta -- python3 -m http.server --bind 0.0.0.0 45101)
reverse=$(agentos project run --detach alpha -- python3 -m http.server --bind 0.0.0.0 45100)
agentos project create gamma >/dev/null
sleep 1
eq "a project agent cannot link" 1 "$(status_of agent alpha -- /usr/sbin/agentos project link alpha beta 45100)"
eq "link refuses one project" 2 "$(status_of agentos project link alpha alpha 45100)"
eq "link refuses an unknown project" 2 "$(status_of agentos project link alpha nobody 45100)"
for bad in 0 65536 045100 '45100;x' ''; do
	eq "link refuses port [$bad]" 2 "$(status_of agentos project link alpha beta "$bad")"
done
eq "refused links leave none" "FROM TO PORT" "$(agentos project links | xargs)"
agentos project link alpha beta 45100
agentos project link alpha beta 45100
eq "a repeated link is listed once" "FROM TO PORT alpha beta 45100" "$(agentos project links beta | xargs)"
eq "a link opens its port" 0 "$(status_of agent alpha -- $connect tcp 10.213.0.6:45100)"
eq "beta serves another port" 0 "$(status_of agent beta -- $connect tcp 45101)"
eq "a link opens no other port" 1 "$(status_of agent alpha -- $connect tcp 10.213.0.6:45101)"
eq "alpha serves the same port" 0 "$(status_of agent alpha -- $connect tcp 45100)"
eq "a link opens one direction" 1 "$(status_of agent beta -- $connect tcp 10.213.0.2:45100)"
eq "a link opens to one project" 1 "$(status_of agent gamma -- $connect tcp 10.213.0.6:45100)"
eq "a link opens no host port" 1 "$(status_of agent alpha -- $connect tcp 10.213.0.5:22)"
systemctl reload agentos-firewall.service
eq "a link survives a firewall reload" 0 "$(status_of agent alpha -- $connect tcp 10.213.0.6:45100)"
# Holds a connection open for four seconds, then sends a request on it.
hold() {
	agentos project run --detach alpha -- python3 -c '
import socket, time
s = socket.create_connection(("10.213.0.6", 45100), timeout=5)
time.sleep(4)
try:
    s.sendall(b"GET / HTTP/1.0\r\n\r\n")
    print("open" if s.recv(1) else "closed")
except OSError:
    print("cut")
'
}
held=$(hold)
sleep 7
eq "an open connection lasts while linked" open "$(agentos project logs alpha "$held" | tail -1)"
eq "the destination sees a link from its gateway" 0 "$(status_of grep -q '^10.213.0.5 ' <(agentos project logs beta "$listener"))"
held=$(hold)
sleep 2
agentos project unlink alpha beta 45100
# The request goes out two seconds from now, and the reply waits five more.
sleep 10
eq "unlink stops an open connection" cut "$(agentos project logs alpha "$held" | tail -1)"
eq "unlink closes the port" 1 "$(status_of agent alpha -- $connect tcp 10.213.0.6:45100)"
eq "unlink removes the listing" "FROM TO PORT" "$(agentos project links | xargs)"
# after_reboot.sh checks that this link returns with the host.
agentos project link alpha beta 45100
agentos project delete gamma --yes
agentos project stop alpha "$reverse"
agentos project stop beta "$other"
agentos project stop beta "$listener"

eq "a host listener is closed to projects" 1 "$(status_of agent alpha -- $connect tcp 10.0.2.15:22)"
eq "projects can resolve names" 0 "$(status_of agent alpha -- getent hosts deb.debian.org)"
eq "projects keep internet access" 0 "$(status_of agent alpha -- curl -fsS -m 20 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release.gpg)"
finish
