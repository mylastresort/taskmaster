#!/bin/bash
# Test script for bonus features: priority, redirect_stderr, process_name

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

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAIL=$((FAIL+1)); BUGS="${BUGS}\n  FAIL: $1"; }

cleanup() {
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
    rm -f $SOCK /tmp/test_taskmaster/server.pid
    rm -f $LOGDIR/*.log
    rm -f $LOGDIR/setup.toml
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
if [ $? -ne 0 ]; then
    echo "FATAL: Build failed"
    exit 1
fi

cleanup
mkdir -p $LOGDIR

# Create setup.toml for the server
cat > $LOGDIR/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/bonus_config.toml"
EOF

# Copy bonus config
cp /home/samy/taskmaster/tests/bonus_config.toml $LOGDIR/bonus_config.toml

echo "=== Starting server ==="
cd $LOGDIR
$SERVER > $LOGDIR/server_output.log 2>&1 &
SERVER_PID=$!
echo $SERVER_PID > $LOGDIR/server.pid
sleep 2

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "FATAL: Server failed to start"
    cat $LOGDIR/server_output.log
    exit 1
fi

echo "Server started with PID $SERVER_PID"

echo ""
echo "=== TEST 1: Priority - autostart order ==="

# Check that high, mid, low are all running
sleep 1
RESULT=$(send_cmd "status all")
echo "  status all: '$RESULT'"

echo "$RESULT" | grep -q "high" && pass "high program started" || fail "high program not found"
echo "$RESULT" | grep -q "mid" && pass "mid program started" || fail "mid program not found"
echo "$RESULT" | grep -q "low" && pass "low program started" || fail "low program not found"

# Check start order from server log: high should start before mid, mid before low
HIGH_LINE=$(grep -n "STARTING.*high" $LOGDIR/server_output.log | head -1 | cut -d: -f1)
MID_LINE=$(grep -n "STARTING.*mid" $LOGDIR/server_output.log | head -1 | cut -d: -f1)
LOW_LINE=$(grep -n "STARTING.*low" $LOGDIR/server_output.log | head -1 | cut -d: -f1)

echo "  start order lines: high=$HIGH_LINE mid=$MID_LINE low=$LOW_LINE"

if [ -n "$HIGH_LINE" ] && [ -n "$MID_LINE" ] && [ -n "$LOW_LINE" ]; then
    if [ "$HIGH_LINE" -lt "$MID_LINE" ] && [ "$MID_LINE" -lt "$LOW_LINE" ]; then
        pass "priority start order: high before mid before low"
    else
        fail "priority start order wrong: expected high($HIGH_LINE) < mid($MID_LINE) < low($LOW_LINE)"
    fi
else
    fail "could not determine start order from server log"
fi

echo ""
echo "=== TEST 2: Priority - stop order ==="

# Stop all - high priority should stop last (reverse order)
send_cmd "stop all" > /dev/null
sleep 3

# Check stop order from server log
HIGH_STOP=$(grep -n "STOPPING.*high" $LOGDIR/server_output.log | tail -1 | cut -d: -f1)
LOW_STOP=$(grep -n "STOPPING.*low" $LOGDIR/server_output.log | tail -1 | cut -d: -f1)

echo "  stop order lines: high=$HIGH_STOP low=$LOW_STOP"

if [ -n "$HIGH_STOP" ] && [ -n "$LOW_STOP" ]; then
    if [ "$LOW_STOP" -lt "$HIGH_STOP" ]; then
        pass "priority stop order: low stopped before high (reverse)"
    else
        fail "priority stop order wrong: expected low($LOW_STOP) < high($HIGH_STOP)"
    fi
else
    fail "could not determine stop order from server log"
fi

echo ""
echo "=== TEST 3: Redirect stderr ==="

send_cmd "start stderr_merge" > /dev/null
sleep 2

RESULT=$(send_cmd "status stderr_merge")
echo "  stderr_merge status: '$RESULT'"

if echo "$RESULT" | grep -q "RUNNING"; then
    pass "stderr_merge started successfully"
else
    fail "stderr_merge should be RUNNING, got: $RESULT"
fi

# Check that stderr output went to stdout log file
sleep 1
if [ -f "$LOGDIR/stderr_merge.log" ]; then
    if grep -q "error_output" "$LOGDIR/stderr_merge.log"; then
        pass "stderr output redirected to stdout log file"
    else
        fail "stderr output not found in stdout log file"
        echo "  log content: $(cat $LOGDIR/stderr_merge.log)"
    fi
else
    fail "stdout log file not created for stderr_merge"
fi

echo ""
echo "=== TEST 4: Process name - custom format ==="

send_cmd "start custom_name" > /dev/null
sleep 2

RESULT=$(send_cmd "status custom_name")
echo "  custom_name status: '$RESULT'"

if echo "$RESULT" | grep -q "custom_custom_name_00" && echo "$RESULT" | grep -q "custom_custom_name_01"; then
    pass "process_name format applied correctly (custom_custom_name_00, custom_custom_name_01)"
else
    fail "process_name format not applied, expected custom_custom_name_00 and custom_custom_name_01, got: $RESULT"
fi

echo ""
echo "=== TEST 5: Process name - default format (no process_name set) ==="

send_cmd "start default_name" > /dev/null
sleep 2

RESULT=$(send_cmd "status default_name")
echo "  default_name status: '$RESULT'"

if echo "$RESULT" | grep -q "default_name_0" && echo "$RESULT" | grep -q "default_name_1" && echo "$RESULT" | grep -q "default_name_2"; then
    pass "default naming works (default_name_0, default_name_1, default_name_2)"
else
    fail "default naming failed, expected default_name_0/1/2, got: $RESULT"
fi

echo ""
echo "=== TEST 6: Process name - single proc (no suffix) ==="

RESULT=$(send_cmd "status high")
echo "  single proc status: '$RESULT'"

if echo "$RESULT" | grep -q "\[high\]"; then
    pass "single proc shows [high] without suffix"
else
    fail "single proc should show [high], got: $RESULT"
fi

echo ""
echo "=============================="
echo -e "RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
if [ $FAIL -gt 0 ]; then
    echo ""
    echo "Failures/Bugs:"
    echo -e "$BUGS"
fi
echo "=============================="
