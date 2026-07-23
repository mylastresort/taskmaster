#!/bin/bash
# Remaining tests D-H

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL+1)); }

send_cmd() {
    echo -ne "$1\r" | nc -U /tmp/test_taskmaster.sock -w 3 2>/dev/null
}

cleanup() {
    kill -9 $(pgrep -d, taskmasterd) 2>/dev/null || true
    kill -9 $(pgrep -d, -f "sleep 3600") 2>/dev/null || true
    kill -9 $(pgrep -d, -f "sleep 0.5") 2>/dev/null || true
    rm -f /tmp/test_taskmaster.sock
    rm -f /tmp/test_taskmaster/*.log
    sleep 1
}

start_server() {
    cleanup
    cd /tmp/test_taskmaster
    /tmp/taskmasterd > /tmp/test_taskmaster/server.log 2>&1 &
    sleep 2
    if ! kill -0 $(pgrep -d, taskmasterd) 2>/dev/null; then
        echo "FATAL: Server failed to start"
        cat /tmp/test_taskmaster/server.log
        exit 1
    fi
}

stop_server() {
    kill -9 $(pgrep -d, taskmasterd) 2>/dev/null || true
    sleep 1
}

# ================================================
echo "=== SECTION C (cont): autorestart=unexpected + unexpected exit ==="
# ================================================

cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/c3b_config.toml"
EOF

cat > /tmp/test_taskmaster/c3b_config.toml << 'EOF'
[program.exitbad]
command = "exit 42"
autostart = true
autorestart = "unexpected"
startsecs = 0
exitcodes = [0]
startretries = 2
EOF

start_server
sleep 15
R=$(send_cmd "status exitbad")
echo "  autorestart=unexpected, exit 42 (unexpected): '$R'"
echo "$R" | grep -q "RUNNING\|STARTING" && pass "C3b: unexpected exit → restarted" || fail "C3b: got '$R' (expected RUNNING, autorestart=unexpected broken)"

stop_server

# ================================================
echo ""
echo "=== SECTION D: Stop Signal Logic ==="
# ================================================

cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/stop_config.toml"
EOF

cat > /tmp/test_taskmaster/stop_config.toml << 'EOF'
[program.termtest]
command = "trap '' TERM; sleep 3600"
autostart = true
autorestart = "false"
startsecs = 0
stopsignal = "TERM"
stopwaitsecs = 3
EOF

start_server
sleep 2

PID=$(pgrep -f "sleep 3600" | head -1)
echo "  Process PID: $PID"

if [ -n "$PID" ]; then
    START=$(date +%s%N)
    send_cmd "stop termtest" > /dev/null
    sleep 1
    ALIVE=$(kill -0 $PID 2>/dev/null && echo "yes" || echo "no")
    END=$(date +%s%N)
    ELAPSED_MS=$(( (END - START) / 1000000 ))
    echo "  Process alive after 1s: $ALIVE (${ELAPSED_MS}ms)"

    if [ "$ALIVE" = "yes" ]; then
        pass "C4: Process survived 1s → graceful signal sent first"
    else
        fail "C4: Process died instantly → SIGKILL sent first (should be stopsignal then SIGKILL)"
    fi

    sleep 4
    R=$(send_cmd "status termtest")
    echo "$R" | grep -q "STOPPED" && pass "D2: Process STOPPED after stopwaitsecs" || fail "D2: got '$R'"
fi

stop_server

# ================================================
echo ""
echo "=== SECTION E: Kill Process → Restart ==="
# ================================================

cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/kill_config.toml"
EOF

cat > /tmp/test_taskmaster/kill_config.toml << 'EOF'
[program.killtest]
command = "sleep 3600"
autostart = true
autorestart = "true"
startsecs = 0
startretries = 3
EOF

start_server
sleep 2

PID1=$(pgrep -f "sleep 3600" | head -1)
echo "  Original PID: $PID1"
R=$(send_cmd "status killtest")
echo "  Before kill: '$R'"

if [ -n "$PID1" ]; then
    kill -9 $PID1 2>/dev/null
    sleep 5
    PID2=$(pgrep -f "sleep 3600" | head -1)
    R=$(send_cmd "status killtest")
    echo "  After kill: '$R', new PID: $PID2"
    echo "$R" | grep -q "RUNNING" && pass "SUP-1: killed process restarted → RUNNING" || fail "SUP-1: killed process → '$R' (expected RUNNING)"
fi

stop_server

# ================================================
echo ""
echo "=== SECTION F: startsecs ==="
# ================================================

cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/secs_config.toml"
EOF

cat > /tmp/test_taskmaster/secs_config.toml << 'EOF'
[program.earlyexit]
command = "exit 0"
autostart = true
autorestart = "false"
startsecs = 5
startretries = 1
exitcodes = [0]
EOF

start_server
sleep 12
R=$(send_cmd "status earlyexit")
echo "  exit 0 with startsecs=5: '$R'"
echo "$R" | grep -q "FATAL" && pass "F1: early exit with startsecs → FATAL (supervisor-correct)" || fail "F1: got '$R'"

stop_server

# ================================================
echo ""
echo "=== SECTION G: startretries ==="
# ================================================

cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/retry_config.toml"
EOF

cat > /tmp/test_taskmaster/retry_config.toml << 'EOF'
[program.retries]
command = "exit 1"
autostart = true
autorestart = "false"
startsecs = 1
startretries = 2
exitcodes = [0]
EOF

start_server
sleep 15
R=$(send_cmd "status retries")
echo "  exit 1, startretries=2: '$R'"
echo "$R" | grep -q "FATAL" && pass "SUP-2: retries exhausted → FATAL" || fail "SUP-2: got '$R'"

stop_server

# ================================================
echo ""
echo "=== SECTION H: Hot-Reload ==="
# ================================================

cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/reload_config.toml"
EOF

cat > /tmp/test_taskmaster/reload_config.toml << 'EOF'
[program.reloadtest]
command = "sleep 3600"
autostart = true
autorestart = "false"
startsecs = 0
EOF

start_server
sleep 2

PID1=$(pgrep -f "sleep 3600" | head -1)
echo "  PID before reload: $PID1"

R=$(send_cmd "reload")
[ -z "$R" ] && pass "HR-1: reload command accepted" || fail "HR-1: got '$R'"

kill -HUP $(pgrep -d, taskmasterd) 2>/dev/null
sleep 2

R=$(send_cmd "status reloadtest")
echo "$R" | grep -q "RUNNING\|STOPPED" && pass "HR-2: SIGHUP reload — server still responds" || fail "HR-2: got '$R'"

PID2=$(pgrep -f "sleep 3600" | head -1)
echo "  PID after reload: $PID2"
if [ "$PID1" = "$PID2" ] && [ -n "$PID1" ]; then
    pass "HR-3: unchanged process NOT restarted (PID preserved)"
else
    fail "HR-3: PID changed from $PID1 to $PID2"
fi

stop_server

# ================================================
echo ""
echo "=== SECTION I: Start/Stop Race Condition ==="
# ================================================
# Test that Stop() waits for Start() to finish launching before acting.
# If Stop() is called before the process has a pgid, the startReady channel
# ensures Stop blocks until Start completes.

cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/race_config.toml"
EOF

cat > /tmp/test_taskmaster/race_config.toml << 'EOF'
[program.racetest]
command = "sleep 3600"
autostart = false
autorestart = "false"
startsecs = 0
stopwaitsecs = 2
EOF

start_server
sleep 1

# Fire start and stop in rapid succession
send_cmd "start racetest" > /dev/null &
sleep 0.1
send_cmd "stop racetest" > /dev/null
sleep 3

R=$(send_cmd "status racetest")
echo "  After rapid start+stop: '$R'"
echo "$R" | grep -q "STOPPED" && pass "RACE-1: start then immediate stop → STOPPED (no runaway process)" || fail "RACE-1: got '$R' (expected STOPPED)"

# Verify no leftover sleep processes from racetest
SLEEP_COUNT=$(pgrep -f "sleep 3600" 2>/dev/null | wc -l)
[ "$SLEEP_COUNT" -eq 0 ] && pass "RACE-2: no leftover sleep processes after race" || fail "RACE-2: $SLEEP_COUNT sleep processes still running"

stop_server

# ================================================
echo ""
echo "========================================"
echo -e "RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"
