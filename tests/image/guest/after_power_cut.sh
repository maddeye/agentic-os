#!/bin/bash
# The same machine after QEMU was killed. The boot credential is absent this time.
source /opt/aos-tests/tests/integration/guest/lib.sh
eq "the system is running with no failed unit" running "$(systemctl is-system-running --wait)"
eq "project data survives" private "$(agentos project run alpha -- cat marker 2>&1)"
eq "the project network returns" 0 "$(status_of agentos project run alpha -- curl -fsS -m 20 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release.gpg)"
between "the data filesystem keeps its size, in GiB" 15 16 "$(df -BG --output=size /var/lib/agent-os | tail -1 | tr -dc 0-9)"
finish
