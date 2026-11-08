#!/bin/bash
source "$(dirname "$0")/lib.sh"
id=$(cat /root/power-change)
eq "the change survives power loss as applying" applying "$(hostctl_ change show "$id" | field state)"
eq "dpkg reports the unfinished package" False "$(hostctl_ status | field dpkg_consistent)"
hostctl_ recover >/dev/null
eq "recovery finishes the change" applied "$(hostctl_ change show "$id" | field state)"
eq "dpkg is consistent after power loss" True "$(hostctl_ status | field dpkg_consistent)"
eq "ripgrep survives reboot" 1 "$(agentos project run beta -- rg --version | grep -c '^ripgrep ')"
eq "the audit log survives reboot" 1 "$(( $(wc -l < "$audit") > 20 ))"
eq "the socket returns after reboot" 0 "$(status_of hostctl_ status)"
finish
