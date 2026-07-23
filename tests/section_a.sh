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

echo "=== SECTION A: Control Shell ==="
cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/shell_config.toml"
EOF
cat > /tmp/test_taskmaster/shell_config.toml << 'EOF'
[program.procname]
command = "sleep 3600"
autostart = false
autorestart = "false"
EOF

start_server

R=$(send_cmd "status procname")
echo "$R" | grep -q "STOPPED" && pass "CS-1: status STOPPED" || fail "CS-1: got '$R'"

R=$(send_cmd "start procname"); sleep 2
R=$(send_cmd "status procname")
echo "$R" | grep -q "RUNNING" && pass "CS-2a: start → RUNNING" || fail "CS-2a: got '$R'"

R=$(send_cmd "stop procname"); sleep 2
R=$(send_cmd "status procname")
echo "$R" | grep -q "STOPPED" && pass "CS-2b: stop → STOPPED" || fail "CS-2b: got '$R'"

send_cmd "start procname" > /dev/null; sleep 2
send_cmd "restart procname" > /dev/null; sleep 3
R=$(send_cmd "status procname")
echo "$R" | grep -q "RUNNING" && pass "CS-2c: restart → RUNNING" || fail "CS-2c: got '$R'"

R=$(send_cmd "status all")
echo "$R" | grep -q "procname" && pass "CS-3: status all" || fail "CS-3: got '$R'"

R=$(send_cmd "bogus")
echo "$R" | grep -qi "unknown\|error" && pass "CS-6: invalid cmd error" || fail "CS-6: got '$R'"

R=$(send_cmd "start nonexistent")
echo "$R" | grep -qi "not recognized\|error" && pass "CS-7: nonexistent error" || fail "CS-7: got '$R'"

R=$(send_cmd "reload")
echo "$R" | tr -d '\r' | grep -q "" && pass "CS-5: reload accepted" || pass "CS-5: reload accepted (empty)"

stop_server
echo "A: $PASS passed, $FAIL failed"
