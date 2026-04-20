#!/usr/bin/env bash
# capture_screenshots.sh
# Run from inside OS-Jackfruit/boilerplate/
# Usage: sudo bash capture_screenshots.sh <path-to-rootfs-base>
#
# Captures all 8 required screenshots as .txt logs.
# View them with: cat screenshots/shot_N_*.txt

set -euo pipefail

ROOTFS="${1:?Usage: sudo bash capture_screenshots.sh <rootfs-base-path>}"
SHOTS="./screenshots"
mkdir -p "$SHOTS"

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\n\033[1;34m>>> $*\033[0m\n"; }
shot() {
    local n="$1" name="$2"
    log "$name"
    echo "==== $name ====" > "$SHOTS/shot_${n}_${name// /_}.txt"
}

# ── 0. Pre-flight ─────────────────────────────────────────────────────────────
log "Loading kernel module..."
lsmod | grep -q "^monitor " && rmmod monitor 2>/dev/null || true
insmod ./monitor.ko
sleep 0.5
ls -la /dev/container_monitor

# ── 1. Start supervisor in background ────────────────────────────────────────
log "Starting supervisor..."
mkdir -p logs
script -q -c "sudo ./engine supervisor $ROOTFS" "$SHOTS/supervisor_session.txt" &
SUPERVISOR_SCRIPT_PID=$!
sleep 2   # let it bind the socket

# ── SCREENSHOT 1: Multi-container supervision ─────────────────────────────────
log "Launching two containers..."
./engine start c1 "$ROOTFS" "/cpu_hog 30"
./engine start c2 "$ROOTFS" "/cpu_hog 30"
sleep 1

shot 1 "multi-container supervision"
./engine ps | tee -a "$SHOTS/shot_1_multi-container_supervision.txt"

# ── SCREENSHOT 2: Metadata tracking ──────────────────────────────────────────
sleep 2
shot 2 "metadata tracking"
./engine ps | tee -a "$SHOTS/shot_2_metadata_tracking.txt"
echo "(engine ps showing container IDs, PIDs, states, limits)" >> "$SHOTS/shot_2_metadata_tracking.txt"

# ── SCREENSHOT 3: Bounded-buffer logging ──────────────────────────────────────
sleep 3
shot 3 "bounded-buffer logging"
{
    echo "--- Log file contents for c1 ---"
    ./engine logs c1
    echo ""
    echo "--- Log file contents for c2 ---"
    ./engine logs c2
    echo ""
    echo "--- Log files on disk ---"
    ls -lh logs/
} | tee -a "$SHOTS/shot_3_bounded-buffer_logging.txt"

# ── SCREENSHOT 4: CLI and IPC ──────────────────────────────────────────────────
shot 4 "CLI and IPC"
{
    echo "--- start command ---"
    ./engine start c3 "$ROOTFS" "/cpu_hog 20" && echo "c3 started OK"
    echo ""
    echo "--- ps command ---"
    ./engine ps
    echo ""
    echo "--- stop command ---"
    ./engine stop c3 && echo "c3 stop sent"
} | tee -a "$SHOTS/shot_4_CLI_and_IPC.txt"

# ── SCREENSHOT 5: Soft-limit warning ─────────────────────────────────────────
log "Launching memory_hog for soft-limit test (soft=10MiB, hard=80MiB)..."
./engine start memsoft "$ROOTFS" "/memory_hog 4 500" \
    --soft-mib 10 --hard-mib 80
sleep 8   # let it exceed 10 MiB soft limit

shot 5 "soft-limit warning"
{
    echo "--- dmesg soft-limit events ---"
    dmesg | grep -i "container_monitor" | grep -i "SOFT" | tail -20
} | tee -a "$SHOTS/shot_5_soft-limit_warning.txt"

./engine stop memsoft 2>/dev/null || true

# ── SCREENSHOT 6: Hard-limit enforcement ──────────────────────────────────────
log "Launching memory_hog for hard-limit test (soft=10MiB, hard=20MiB)..."
./engine start memhard "$ROOTFS" "/memory_hog 4 300" \
    --soft-mib 10 --hard-mib 20
sleep 10  # let it exceed 20 MiB hard limit and get killed

shot 6 "hard-limit enforcement"
{
    echo "--- dmesg hard-limit (KILL) events ---"
    dmesg | grep -i "container_monitor" | grep -i "HARD\|KILL" | tail -20
    echo ""
    echo "--- container state after kill ---"
    ./engine ps
} | tee -a "$SHOTS/shot_6_hard-limit_enforcement.txt"

# ── SCREENSHOT 7: Scheduling experiment ──────────────────────────────────────
log "Scheduling experiment: nice 0 vs nice 15..."
# Launch two cpu_hogs — one normal priority, one low priority
./engine start sched_hi "$ROOTFS" "/cpu_hog 15" --nice 0
./engine start sched_lo "$ROOTFS" "/cpu_hog 15" --nice 15
sleep 5

shot 7 "scheduling experiment"
{
    echo "--- containers: normal vs low priority ---"
    ./engine ps
    echo ""
    echo "--- host-side ps showing nice values ---"
    ps -o pid,ni,comm,pcpu --sort=-pcpu | grep -E "cpu_hog|PID" | head -10
    echo ""
    echo "--- logs from high-priority container ---"
    ./engine logs sched_hi | tail -5
    echo ""
    echo "--- logs from low-priority container ---"
    ./engine logs sched_lo | tail -5
} | tee -a "$SHOTS/shot_7_scheduling_experiment.txt"

# wait for scheduling experiment to finish
sleep 12

# ── SCREENSHOT 8: Clean teardown ──────────────────────────────────────────────
log "Stopping remaining containers and shutting down supervisor..."
./engine stop c1 2>/dev/null || true
./engine stop c2 2>/dev/null || true
sleep 2

# Signal supervisor to exit
kill "$SUPERVISOR_SCRIPT_PID" 2>/dev/null || true
pkill -f "engine supervisor" 2>/dev/null || true
sleep 2

shot 8 "clean teardown"
{
    echo "--- ps aux: no zombie container processes ---"
    ps aux | grep -E "cpu_hog|memory_hog|engine" | grep -v grep || echo "(none — clean)"
    echo ""
    echo "--- dmesg: module unload messages ---"
    dmesg | grep "container_monitor" | tail -5
    echo ""
    echo "--- /tmp/mini_runtime.sock gone ---"
    ls /tmp/mini_runtime.sock 2>/dev/null && echo "WARNING: socket still exists" || echo "socket cleaned up OK"
} | tee -a "$SHOTS/shot_8_clean_teardown.txt"

rmmod monitor 2>/dev/null || true
log "All done. Screenshots saved in $SHOTS/"
ls -lh "$SHOTS/"
