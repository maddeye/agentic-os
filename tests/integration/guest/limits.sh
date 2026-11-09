#!/bin/bash
source "$(dirname "$0")/lib.sh"
agent() { agentos project run "$@"; }
alloc() { echo "x = b'\\1' * ($1 << 20); import time; time.sleep($2)"; }
spawn() { echo "import subprocess; [subprocess.Popen(['sleep', '20']) for _ in range($1)]; import time; time.sleep(20)"; }
burn="import time
start = time.perf_counter()
while time.perf_counter() - start < 3: pass
print(int(100 * time.process_time() / 3))"

agentos project create capped --cpu 50 --memory-max 512M --tasks 128 >/dev/null
agentos project create free >/dev/null

between "unlimited project gets a full core (%)" 85 110 "$(agent free -- python3 -c "$burn")"
between "CPU quota holds at 50% (%)" 30 65 "$(agent capped -- python3 -c "$burn")"

eq "allocation under the limit works" 0 "$(status_of agent capped -- python3 -c "$(alloc 256 0)")"
eq "allocation over the limit fails" 1 "$(status_of agent capped -- python3 -c "$(alloc 768 0)")"

# Two commands must share one budget. Each fits alone, and together they do not.
agentos project run --detach capped -- python3 -c "$(alloc 300 25)" >/dev/null
sleep 3
eq "one command fits in the memory limit" 1 "$(agentos project ps capped | wc -l)"
agentos project run --detach capped -- python3 -c "$(alloc 300 25)" >/dev/null
sleep 5
# The kernel can kill both, because the first victim still holds its memory when the second allocates.
between "memory limit covers all commands together (survivors)" 0 1 "$(agentos project ps capped | wc -l)"
agentos project stop capped

eq "process count under the limit works" 0 "$(status_of agent capped -- python3 -c 'import subprocess; [subprocess.Popen(["sleep", "1"]) for _ in range(50)]')"
eq "process count over the limit fails" 1 "$(status_of agent capped -- python3 -c 'import subprocess; [subprocess.Popen(["sleep", "1"]) for _ in range(200)]')"
sleep 2
agentos project run --detach capped -- python3 -c "$(spawn 80)" >/dev/null
sleep 2
eq "task limit covers all commands together" 1 "$(status_of agent capped -- python3 -c 'import subprocess; [subprocess.Popen(["sleep", "1"]) for _ in range(80)]')"
agentos project stop capped

# Each project may use 80% of RAM. The parent slice caps them together at 85%.
agentos project create hog1 >/dev/null
agentos project create hog2 >/dev/null
agentos project run --detach hog1 -- python3 -c "$(alloc 1800 25)" >/dev/null
sleep 4
eq "one project fits in the parent limit" 1 "$(agentos project ps hog1 | wc -l)"
agentos project run --detach hog2 -- python3 -c "$(alloc 1800 25)" >/dev/null
sleep 6
total=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
peak=$(( $(cat /sys/fs/cgroup/agentos.slice/agentos-project.slice/memory.peak) >> 20 ))
# systemd computes 85% of physical RAM, which is slightly more than MemTotal.
between "parent slice stays near 85% of RAM (MiB)" 1 $(( total * 86 / 100 )) "$peak"
between "parent limit stopped a project (survivors)" 0 1 "$(( $(agentos project ps hog1 | wc -l) + $(agentos project ps hog2 | wc -l) ))"
eq "SSH service survives" active "$(systemctl is-active ssh)"
for name in capped free hog1 hog2; do agentos project delete "$name" --yes; done
finish
