#!/bin/bash
# Prints one boot's measurements as key<TAB>number lines. Runs as root after boot.
set -euo pipefail
agentos project create alpha >/dev/null
row() { printf '%s\t%s\n' "$1" "$2"; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

systemctl is-system-running --wait >/dev/null || true
boot=$(systemd-analyze time | sed -n '1p')
seconds() { # <label> converts "1.234s" or "567ms" after the label
	sed -nE "s/.* ([0-9.]+)(m?s) \($1\).*/\1 \2/p" <<<"$boot" | awk '{print ($2=="ms") ? $1/1000 : $1}'
}
row "Boot, kernel (s)" "$(seconds kernel)"
row "Boot, userspace (s)" "$(seconds userspace)"

sleep 30
read -r _ u1 n1 s1 i1 w1 q1 sq1 _ < /proc/stat
sleep 30
read -r _ u2 n2 s2 i2 w2 q2 sq2 _ < /proc/stat
busy=$(( (u2-u1)+(n2-n1)+(s2-s1)+(q2-q1)+(sq2-sq1) ))
idle=$(( (i2-i1)+(w2-w1) ))
row "Idle CPU, all vCPUs (%)" "$(awk -v b=$busy -v i=$idle 'BEGIN{printf "%.2f", 100*b/(b+i)}')"
row "Idle memory used (MiB)" "$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.0f",(t-a)/1024}' /proc/meminfo)"
row "Processes at idle" "$(ps -e --no-headers | wc -l)"
row "Root disk used (MiB)" "$(df -BM --output=used / | tail -1 | tr -dc 0-9)"

spawn_ms() { # <command...> prints the mean no-op command time over 20 runs
	local start
	start=$(now_ms)
	for _ in $(seq 1 20); do "$@" </dev/null; done
	echo $(( ($(now_ms) - start) / 20 ))
}
row "No-op unit, plain (ms)" "$(spawn_ms systemd-run --wait --pipe --collect --quiet --uid=aos-alpha --gid=aos-alpha -- /usr/bin/true)"
row "No-op command, agentos project run (ms)" "$(spawn_ms agentos project run alpha -- /usr/bin/true)"

row "SHA-256, one core (MiB/s)" "$(python3 -c '
import hashlib, time
data = bytes(1 << 20)
start = time.perf_counter()
digest = hashlib.sha256()
for _ in range(1024):
    digest.update(data)
print(round(1024 / (time.perf_counter() - start)))')"

write_mib_s() { # <directory>
	local start elapsed
	start=$(now_ms)
	dd if=/dev/urandom of="$1/.bench" bs=1M count=512 oflag=direct status=none
	elapsed=$(( $(now_ms) - start ))
	rm -f "$1/.bench"
	awk -v ms=$elapsed 'BEGIN{printf "%.0f", 512000/ms}'
}
row "Direct write, ext4 root (MiB/s)" "$(write_mib_s /root)"
row "Direct write, Btrfs data (MiB/s)" "$(write_mib_s /var/lib/agent-os)"
