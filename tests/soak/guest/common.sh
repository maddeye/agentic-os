# Names and measurements shared by the soak steps. Source this file.
source "$(dirname "${BASH_SOURCE[0]}")/../../integration/guest/lib.sh"
steady=(one two three)
state=/var/tmp/aos-soak
slice=/sys/fs/cgroup/agentos.slice/agentos-project.slice
agent() { agentos project run "$@"; }
mem_available() { awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo; }
data_used() { df -m --output=used /var/lib/agent-os | tail -1 | tr -d ' '; }
drop_caches() { sync; echo 3 > /proc/sys/vm/drop_caches; }
