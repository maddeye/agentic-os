#!/bin/bash
# Refused backups must leave nothing behind on the fresh VM.
source "$(dirname "$0")/lib.sh"
eq "refused backups create no project" 0 "$(ls "$projects" | wc -l)"
eq "refused backups create no registry entry" 0 "$(ls "$registry" | wc -l)"
eq "refused backups create no spool" 0 "$(ls -A "$snapshots" | wc -l)"
eq "refused backups create no account" 2 "$(status_of getent passwd aos-crafted)"
eq "refused backups keep the UID counter" 1 "$(status_of test -e /var/lib/agent-os/metadata/next-uid)"
finish
