#!/bin/bash
# Leaves a session with a red window for the remote-viewing check on the host.
source "$(dirname "$0")/lib.sh"
eq "viewing session starts" 0 "$(status_of gui alpha start view --size 800x600)"
gui alpha run view -- python3 "$app" >/dev/null
eq "the window appears" 0 "$(status_of gui alpha wait view --window agentostest)"
finish
