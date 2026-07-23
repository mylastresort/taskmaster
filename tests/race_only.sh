#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL+1)); }

send_cmd() {
    echo -ne "$1\r" | nc -U /tmp/test_taskmaster.sock -w 3 2>/dev/null
}

cleanup() {
    kill -9 $(pgrep -x taskmasterd) 2>/dev/null || true
    kill -9 $(pgrep -x sleep) 2>/dev/null || true
    rm -f /tmp/test_taskmaster.sock
    rm -f /tmp/test_taskmaster/*.log
    sleep 1
}

start_server() {
    cleanup
    cd /tmp/test_taskmaster
    /tmp/taskmasterd > /tmp/test_taskmaster/server.log 2>&1 &
    sleep 2
    if ! pgrep -x taskmasterd > /dev/null 2>&1; then
        echo "FATAL: Server failed to start"
        cat /tmp/test_taskmaster/server.log
        exit 1
    fi
}

stop_server() {
    kill -9 $(pgrep -x taskmasterd) 2>/dev/null || true
    sleep 1
}

echo "=== SECTION I: Start/Stop Race Condition ==="

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

send_cmd "start racetest" > /dev/null &
sleep 0.1
send_cmd "stop racetest" > /dev/null
sleep 3

R=$(send_cmd "status racetest")
echo "  After rapid start+stop: '$R'"
echo "$R" | grep -q "STOPPED" && pass "RACE-1: start then immediate stop → STOPPED" || fail "RACE-1: got '$R'"

SLEEP_COUNT=$(pgrep -x sleep 2>/dev/null | wc -l)
[ "$SLEEP_COUNT" -eq 0 ] && pass "RACE-2: no leftover sleep processes" || fail "RACE-2: $SLEEP_COUNT sleep processes still running"

stop_server

echo ""
echo "========================================"
echo -e "RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"
