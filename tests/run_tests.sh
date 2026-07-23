#!/bin/bash
# Comprehensive test script for taskmaster

SERVER=/tmp/taskmasterd
CLIENT=/tmp/taskmasterctl
SOCK=/tmp/test_taskmaster.sock
LOGDIR=/tmp/test_taskmaster

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
BUGS=""

pass() { echo -e "${GREEN}PASS${NC}: $1"; ((PASS++)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((FAIL++)); BUGS="${BUGS}\n  FAIL: $1"; }
bug() { echo -e "${YELLOW}BUG${NC}: $1"; ((FAIL++)); BUGS="${BUGS}\n  BUG: $1"; }

cleanup() {
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
    rm -f $SOCK /tmp/test_taskmaster/server.pid
    rm -f $LOGDIR/*.log
    # kill any leftover sleep 3600
    pkill -f "sleep 3600" 2>/dev/null
}

send_cmd() {
    echo -ne "$1\r" | nc -U $SOCK -w 3
}

trap cleanup EXIT

# Build
cd /home/samy/taskmaster
go build -o $SERVER cmd/server/main.go 2>/dev/null
go build -o $CLIENT cmd/client/main.go 2>/dev/null

cleanup

echo "=== Starting server ==="
cd $LOGDIR
$SERVER > /tmp/test_taskmaster/server_output.log 2>&1 &
SERVER_PID=$!
echo $SERVER_PID > /tmp/test_taskmaster/server.pid
sleep 2

# Check server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "FATAL: Server failed to start"
    cat /tmp/test_taskmaster/server_output.log
    exit 1
fi

echo "Server started with PID $SERVER_PID"

echo ""
echo "=== TEST 1: Basic control shell (start/stop/restart/status) ==="

RESULT=$(send_cmd "status stayalive")
echo "  status stayalive: '$RESULT'"
if echo "$RESULT" | grep -q "STOPPED"; then
    pass "status shows STOPPED for non-started program"
else
    fail "status should show STOPPED, got: $RESULT"
fi

RESULT=$(send_cmd "start stayalive")
echo "  start stayalive: '$RESULT'"
sleep 3

RESULT=$(send_cmd "status stayalive")
echo "  status after start: '$RESULT'"
if echo "$RESULT" | grep -q "RUNNING"; then
    pass "start works - status shows RUNNING"
else
    fail "start failed - expected RUNNING, got: $RESULT"
fi

RESULT=$(send_cmd "stop stayalive")
echo "  stop stayalive: '$RESULT'"
sleep 3

RESULT=$(send_cmd "status stayalive")
echo "  status after stop: '$RESULT'"
if echo "$RESULT" | grep -q "STOPPED"; then
    pass "stop works - status shows STOPPED"
else
    fail "stop failed - expected STOPPED, got: $RESULT"
fi

send_cmd "start stayalive" > /dev/null
sleep 3
RESULT=$(send_cmd "restart stayalive")
echo "  restart stayalive: '$RESULT'"
sleep 3

RESULT=$(send_cmd "status stayalive")
echo "  status after restart: '$RESULT'"
if echo "$RESULT" | grep -q "RUNNING"; then
    pass "restart works - status shows RUNNING"
else
    fail "restart failed - expected RUNNING, got: $RESULT"
fi

RESULT=$(send_cmd "status all")
echo "  status all: '$RESULT'"
if echo "$RESULT" | grep -q "stayalive"; then
    pass "status all shows programs"
else
    fail "status all should list programs, got: $RESULT"
fi

echo ""
echo "=== TEST 2: Configuration - autostart ==="

RESULT=$(send_cmd "status stayalive")
if echo "$RESULT" | grep -q "RUNNING"; then
    pass "autostart=true program started automatically"
else
    fail "autostart=true should be running, got: $RESULT"
fi

RESULT=$(send_cmd "status fastexit")
if echo "$RESULT" | grep -q "STOPPED"; then
    pass "autostart=false program not started"
else
    fail "autostart=false should be STOPPED, got: $RESULT"
fi

echo ""
echo "=== TEST 3: Configuration - numprocs ==="

send_cmd "start multihello" > /dev/null
sleep 2
RESULT=$(send_cmd "status multihello")
echo "  multihello status: '$RESULT'"
if echo "$RESULT" | grep -q "multihello_0" && echo "$RESULT" | grep -q "multihello_1" && echo "$RESULT" | grep -q "multihello_2"; then
    pass "numprocs=3 shows 3 processes"
else
    fail "numprocs=3 should show 3 process statuses, got: $RESULT"
fi

echo ""
echo "=== TEST 4: Configuration - autorestart ==="

send_cmd "start fastexit" > /dev/null
sleep 3
RESULT=$(send_cmd "status fastexit")
echo "  fastexit (autorestart=false) status: '$RESULT'"
if echo "$RESULT" | grep -q "EXITED"; then
    pass "autorestart=false: process exited and not restarted"
else
    fail "autorestart=false: expected EXITED, got: $RESULT"
fi

send_cmd "start error_exit" > /dev/null
sleep 3
RESULT=$(send_cmd "status error_exit")
echo "  error_exit (autorestart=true) status: '$RESULT'"
if echo "$RESULT" | grep -q "RUNNING\|BACKOFF"; then
    pass "autorestart=true: process restarted after exit"
else
    fail "autorestart=true: expected RUNNING/BACKOFF, got: $RESULT"
fi

echo ""
echo "=== TEST 5: Kill supervised process -> auto restart ==="

send_cmd "stop stayalive" > /dev/null
sleep 2
send_cmd "start stayalive" > /dev/null
sleep 3

PROC_PID=$(pgrep -f "sleep 3600" | head -1)
echo "  supervised process PID: $PROC_PID"
if [ -n "$PROC_PID" ]; then
    kill -9 $PROC_PID 2>/dev/null
    sleep 4
    RESULT=$(send_cmd "status stayalive")
    echo "  after kill status: '$RESULT'"
    if echo "$RESULT" | grep -q "RUNNING"; then
        pass "killed process was automatically restarted"
    else
        fail "killed process should be restarted, got: $RESULT"
    fi
else
    fail "could not find supervised process PID"
fi

echo ""
echo "=== TEST 6: startretries -> abort after max retries ==="

send_cmd "stop error_exit" > /dev/null 2>/dev/null
sleep 1
send_cmd "start error_exit" > /dev/null 2>/dev/null
sleep 20

RESULT=$(send_cmd "status error_exit")
echo "  after retries status: '$RESULT'"
if echo "$RESULT" | grep -q "FATAL"; then
    pass "startretries exhausted -> FATAL state"
else
    fail "expected FATAL after retries exhausted, got: $RESULT"
fi

echo ""
echo "=== TEST 7: Hot-reload (SIGHUP + reload command) ==="

RESULT=$(send_cmd "reload")
echo "  reload command result: '$RESULT'"
if [ -z "$RESULT" ]; then
    pass "reload command accepted (empty = success)"
else
    echo "$RESULT" | grep -qi "error" && fail "reload command failed: $RESULT" || pass "reload command accepted"
fi

kill -HUP $SERVER_PID 2>/dev/null
sleep 2
RESULT=$(send_cmd "status stayalive")
if echo "$RESULT" | grep -q "RUNNING\|STOPPED\|EXITED"; then
    pass "SIGHUP reload - server still responding"
else
    fail "server not responding after SIGHUP, got: '$RESULT'"
fi

echo ""
echo "=== TEST 8: Hot-reload - unchanged processes not restarted ==="

send_cmd "stop stayalive" > /dev/null
sleep 2
send_cmd "start stayalive" > /dev/null
sleep 3

PROC_PID1=$(pgrep -f "sleep 3600" | head -1)
echo "  PID before reload: $PROC_PID1"

kill -HUP $SERVER_PID 2>/dev/null
sleep 2

PROC_PID2=$(pgrep -f "sleep 3600" | head -1)
echo "  PID after reload: $PROC_PID2"

if [ "$PROC_PID1" = "$PROC_PID2" ] && [ -n "$PROC_PID1" ]; then
    pass "unchanged process NOT restarted on reload (PID preserved)"
elif [ -n "$PROC_PID1" ] && [ -n "$PROC_PID2" ]; then
    bug "unchanged process WAS restarted on reload (PID changed from $PROC_PID1 to $PROC_PID2)"
else
    fail "could not determine PIDs (before=$PROC_PID1, after=$PROC_PID2)"
fi

echo ""
echo "=== TEST 9: stopwaitsecs (graceful stop) ==="

send_cmd "start graceful" > /dev/null
sleep 2

RESULT=$(send_cmd "status graceful")
echo "  graceful before stop: '$RESULT'"

START_TIME=$(date +%s)
send_cmd "stop graceful" > /dev/null
sleep 1
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "  stop command returned after ${ELAPSED}s"

sleep 3
RESULT=$(send_cmd "status graceful")
echo "  graceful after stop: '$RESULT'"
if echo "$RESULT" | grep -q "STOPPED"; then
    pass "graceful stop completed"
else
    fail "graceful stop did not complete, got: $RESULT"
fi

echo ""
echo "=== TEST 10: stdout/stderr log files ==="

send_cmd "stop stayalive" > /dev/null
sleep 1
send_cmd "start stayalive" > /dev/null
sleep 2

if [ -f "$LOGDIR/stayalive.log" ]; then
    pass "stdout log file created"
    echo "  content: $(head -c 200 $LOGDIR/stayalive.log)"
else
    fail "stdout log file not created"
fi

if [ -f "$LOGDIR/stayalive_err.log" ]; then
    pass "stderr log file created"
else
    fail "stderr log file not created"
fi

echo ""
echo "=== TEST 11: Environment variables ==="

send_cmd "start envcheck" > /dev/null
sleep 2

if [ -f "$LOGDIR/env.log" ]; then
    if grep -q "MY_VAR=hello42" "$LOGDIR/env.log"; then
        pass "environment variable MY_VAR set correctly"
    else
        fail "MY_VAR=hello42 not found in env output"
    fi
    if grep -q "ANOTHER_VAR=world" "$LOGDIR/env.log"; then
        pass "environment variable ANOTHER_VAR set correctly"
    else
        fail "ANOTHER_VAR=world not found in env output"
    fi
else
    fail "env.log not created"
fi

echo ""
echo "=== TEST 12: Working directory ==="

send_cmd "start dircheck" > /dev/null
sleep 2

if [ -f "$LOGDIR/dir.log" ]; then
    CONTENT=$(cat "$LOGDIR/dir.log" | tr -d '\n')
    if echo "$CONTENT" | grep -q "/tmp"; then
        pass "working directory set to /tmp"
    else
        fail "working directory should be /tmp, got: $CONTENT"
    fi
else
    fail "dir.log not created"
fi

echo ""
echo "=== TEST 13: Umask ==="

send_cmd "start umaskcheck" > /dev/null
sleep 2

if [ -f "$LOGDIR/umask.log" ]; then
    CONTENT=$(cat "$LOGDIR/umask.log" | tr -d '\n')
    if echo "$CONTENT" | grep -q "0077\|00077"; then
        pass "umask set to 0077"
    else
        fail "umask should be 0077, got: '$CONTENT'"
    fi
else
    fail "umask.log not created"
fi

echo ""
echo "=== TEST 14: Invalid commands / non-existent jobs ==="

RESULT=$(send_cmd "bogus")
echo "  bogus command: '$RESULT'"
if echo "$RESULT" | grep -qi "unknown\|error"; then
    pass "invalid command returns error"
else
    fail "invalid command should return error, got: $RESULT"
fi

RESULT=$(send_cmd "start nonexistent")
echo "  start nonexistent: '$RESULT'"
if echo "$RESULT" | grep -qi "not recognized\|error\|unknown"; then
    pass "non-existent job returns error"
else
    fail "non-existent job should return error, got: $RESULT"
fi

echo ""
echo "=== TEST 15: start/stop all ==="

send_cmd "stop all" > /dev/null
sleep 3
RESULT=$(send_cmd "status all")
echo "  status after stop all: '$RESULT'"
echo "$RESULT" | grep -q "RUNNING" && fail "stop all did not stop everything" || pass "stop all works"

send_cmd "start all" > /dev/null
sleep 3
RESULT=$(send_cmd "status all")
echo "  status after start all: '$RESULT'"
echo "$RESULT" | grep -q "RUNNING" && pass "start all works" || fail "start all did not start autostart programs"

echo ""
echo "=============================="
echo -e "RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
if [ $FAIL -gt 0 ]; then
    echo ""
    echo "Failures/Bugs:"
    echo -e "$BUGS"
fi
echo "=============================="
