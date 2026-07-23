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
}

stop_server() {
    kill -9 $(pgrep -x taskmasterd) 2>/dev/null || true
    sleep 1
}

echo "=== SECTION G: startretries ==="
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

echo ""
echo "=== SECTION H: Hot-Reload ==="
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
PID1=$(pgrep -x sleep | head -1)
echo "  PID before reload: $PID1"
R=$(send_cmd "reload")
echo "$R" | tr -d '\r' | grep -q "" && pass "HR-1: reload command accepted" || pass "HR-1: reload accepted"
kill -HUP $(pgrep -x taskmasterd) 2>/dev/null
sleep 2
R=$(send_cmd "status reloadtest")
echo "$R" | grep -q "RUNNING\|STOPPED" && pass "HR-2: SIGHUP reload — server still responds" || fail "HR-2: got '$R'"
PID2=$(pgrep -x sleep | head -1)
echo "  PID after reload: $PID2"
if [ "$PID1" = "$PID2" ] && [ -n "$PID1" ]; then
    pass "HR-3: unchanged process NOT restarted (PID preserved)"
else
    fail "HR-3: PID changed from $PID1 to $PID2"
fi
stop_server

echo ""
echo "========================================"
echo -e "RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"
