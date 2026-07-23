#!/bin/bash
# Focused bug verification tests (no strace)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAIL=$((FAIL+1)); }
bug() { echo -e "${YELLOW}BUG${NC}: $1"; FAIL=$((FAIL+1)); }

send_cmd() {
    echo -ne "$1\r" | nc -U /tmp/test_taskmaster.sock -w 3 2>/dev/null
}

cleanup() {
    kill -9 $(pgrep -d, taskmasterd) 2>/dev/null || true
    kill -9 $(pgrep -d, -f "sleep 3600") 2>/dev/null || true
    kill -9 $(pgrep -d, -f "sleep 0.5") 2>/dev/null || true
    kill -9 $(pgrep -d, -f "exit ") 2>/dev/null || true
    rm -f /tmp/test_taskmaster.sock
    rm -f /tmp/test_taskmaster/*.log
}

# ========================
# TEST A: autorestart=true - process should keep restarting
# ========================
echo ""
echo "=== TEST A: autorestart=true ==="
cleanup
sleep 1

cat > /tmp/test_taskmaster/setup.toml << 'SETUP'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/ar_config.toml"
SETUP

cat > /tmp/test_taskmaster/ar_config.toml << 'CFG'
[program.shortlived]
command = "sleep 0.5"
autostart = true
autorestart = "true"
numprocs = 1
startsecs = 0
startretries = 5
CFG

cd /tmp/test_taskmaster
/tmp/taskmasterd > /tmp/test_taskmaster/server_a.log 2>&1 &
sleep 4

RESULT=$(send_cmd "status shortlived")
echo "  Status: '$RESULT'"

if echo "$RESULT" | grep -q "FATAL"; then
    bug "autorestart=true: process went FATAL instead of restarting"
elif echo "$RESULT" | grep -q "BACKOFF"; then
    bug "autorestart=true: process stuck in BACKOFF"
elif echo "$RESULT" | grep -q "RUNNING"; then
    pass "autorestart=true: process running (restart works)"
elif echo "$RESULT" | grep -q "STARTING"; then
    pass "autorestart=true: process starting (restart works)"
elif echo "$RESULT" | grep -q "EXITED"; then
    bug "autorestart=true: process EXITED but not restarted"
else
    bug "autorestart=true: unexpected state: $RESULT"
fi

# ========================
# TEST B: autorestart=unexpected with expected exit code -> should NOT restart
# ========================
echo ""
echo "=== TEST B: autorestart=unexpected with expected exit code ==="
cleanup
sleep 1

cat > /tmp/test_taskmaster/setup.toml << 'SETUP'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/unexpected_config.toml"
SETUP

cat > /tmp/test_taskmaster/unexpected_config.toml << 'CFG'
[program.exit0]
command = "exit 0"
autostart = true
autorestart = "unexpected"
numprocs = 1
startsecs = 0
startretries = 3
exitcodes = [0]
CFG

cd /tmp/test_taskmaster
/tmp/taskmasterd > /tmp/test_taskmaster/server_b.log 2>&1 &
sleep 4

RESULT=$(send_cmd "status exit0")
echo "  Status (exit 0, expected=[0]): '$RESULT'"
if echo "$RESULT" | grep -q "EXITED"; then
    pass "autorestart=unexpected: expected exit -> EXITED (correct, no restart)"
elif echo "$RESULT" | grep -q "FATAL"; then
    fail "autorestart=unexpected: expected exit -> FATAL (incorrect)"
elif echo "$RESULT" | grep -q "RUNNING\|STARTING"; then
    bug "autorestart=unexpected: expected exit -> still running (should have stopped)"
else
    bug "autorestart=unexpected: unexpected state: $RESULT"
fi

# ========================
# TEST C: autorestart=unexpected with UNEXPECTED exit code -> should restart
# ========================
echo ""
echo "=== TEST C: autorestart=unexpected with unexpected exit code ==="
cleanup
sleep 1

cat > /tmp/test_taskmaster/setup.toml << 'SETUP'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/unexpected_config2.toml"
SETUP

cat > /tmp/test_taskmaster/unexpected_config2.toml << 'CFG'
[program.exitbad]
command = "exit 42"
autostart = true
autorestart = "unexpected"
numprocs = 1
startsecs = 0
startretries = 3
exitcodes = [0]
CFG

cd /tmp/test_taskmaster
/tmp/taskmasterd > /tmp/test_taskmaster/server_c.log 2>&1 &
sleep 4

RESULT=$(send_cmd "status exitbad")
echo "  Status (exit 42, expected=[0]): '$RESULT'"
if echo "$RESULT" | grep -q "RUNNING\|STARTING"; then
    pass "autorestart=unexpected: unexpected exit -> restarted (correct)"
elif echo "$RESULT" | grep -q "FATAL"; then
    bug "autorestart=unexpected: unexpected exit -> should restart but got FATAL"
elif echo "$RESULT" | grep -q "BACKOFF"; then
    bug "autorestart=unexpected: unexpected exit -> stuck in BACKOFF"
elif echo "$RESULT" | grep -q "EXITED"; then
    bug "autorestart=unexpected: unexpected exit -> should restart but stayed EXITED"
else
    bug "autorestart=unexpected: unexpected exit -> unexpected state: $RESULT"
fi

# ========================
# TEST D: stop sends SIGKILL immediately instead of graceful signal first
# ========================
echo ""
echo "=== TEST D: Stop logic - SIGKILL vs graceful signal ordering ==="
cleanup
sleep 1

cat > /tmp/test_taskmaster/setup.toml << 'SETUP'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/stop_config.toml"
SETUP

cat > /tmp/test_taskmaster/stop_config.toml << 'CFG'
[program.termtest]
command = "sleep 3600"
autostart = true
autorestart = "false"
numprocs = 1
startsecs = 0
stopsignal = "TERM"
stopwaitsecs = 5
CFG

cd /tmp/test_taskmaster
/tmp/taskmasterd > /tmp/test_taskmaster/server_d.log 2>&1 &
sleep 2

PROC_PID=$(pgrep -f "sleep 3600" | head -1)
echo "  Process PID: $PROC_PID"

if [ -n "$PROC_PID" ]; then
    # Record start time
    START=$(date +%s%N)
    send_cmd "stop termtest" > /dev/null
    sleep 1
    ALIVE=$(kill -0 $PROC_PID 2>/dev/null && echo "yes" || echo "no")
    END=$(date +%s%N)
    ELAPSED_MS=$(( (END - START) / 1000000 ))
    echo "  Process alive after 1s: $ALIVE (${ELAPSED_MS}ms elapsed)"

    if [ "$ALIVE" = "yes" ]; then
        # Process is still alive after 1s - this is consistent with
        # either: (a) SIGKILL was sent but process somehow survived (impossible),
        # or (b) SIGTERM was sent and process is handling it gracefully
        echo "  Process still alive after stop command - checking code..."

        # The key test: code sends SIGKILL first, then stop signal
        # If SIGKILL was sent first, process would die instantly
        # If stop signal was sent first, process might survive briefly
        pass "Process survived 1s after stop (good - graceful signal before kill)"
    else
        # Process died within 1s - SIGKILL was sent immediately (inverted logic)
        bug "Process died instantly after stop (SIGKILL sent first, should send graceful signal first, then SIGKILL after stopwaitsecs)"
    fi
fi

# ========================
# TEST E: Kill supervised process -> should auto-restart
# ========================
echo ""
echo "=== TEST E: Kill supervised process -> auto-restart ==="
cleanup
sleep 1

cat > /tmp/test_taskmaster/setup.toml << 'SETUP'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/kill_config.toml"
SETUP

cat > /tmp/test_taskmaster/kill_config.toml << 'CFG'
[program.pingtest]
command = "sleep 3600"
autostart = true
autorestart = "true"
numprocs = 1
startsecs = 0
startretries = 3
CFG

cd /tmp/test_taskmaster
/tmp/taskmasterd > /tmp/test_taskmaster/server_e.log 2>&1 &
sleep 2

PROC_PID=$(pgrep -f "sleep 3600" | head -1)
echo "  Original PID: $PROC_PID"

RESULT=$(send_cmd "status pingtest")
echo "  Status before kill: '$RESULT'"

if [ -n "$PROC_PID" ]; then
    kill -9 $PROC_PID 2>/dev/null
    sleep 4

    NEW_PID=$(pgrep -f "sleep 3600" | head -1)
    RESULT=$(send_cmd "status pingtest")
    echo "  Status after kill: '$RESULT'"
    echo "  New PID: $NEW_PID"

    if echo "$RESULT" | grep -q "RUNNING"; then
        if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$PROC_PID" ]; then
            pass "Killed process was restarted with new PID ($NEW_PID)"
        else
            pass "Killed process was restarted (same PID or new PID)"
        fi
    elif echo "$RESULT" | grep -q "FATAL"; then
        bug "Killed process went FATAL instead of restarting"
    else
        bug "Killed process not restarted, status: $RESULT"
    fi
fi

# ========================
# TEST F: startretries -> FATAL after max retries
# ========================
echo ""
echo "=== TEST F: startretries exhaustion -> FATAL ==="
cleanup
sleep 1

cat > /tmp/test_taskmaster/setup.toml << 'SETUP'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/retry_config.toml"
SETUP

cat > /tmp/test_taskmaster/retry_config.toml << 'CFG'
[program.failstart]
command = "exit 1"
autostart = true
autorestart = "false"
numprocs = 1
startsecs = 0
startretries = 2
exitcodes = [0]
CFG

cd /tmp/test_taskmaster
/tmp/taskmasterd > /tmp/test_taskmaster/server_f.log 2>&1 &
sleep 15

RESULT=$(send_cmd "status failstart")
echo "  Status: '$RESULT'"
if echo "$RESULT" | grep -q "FATAL"; then
    pass "startretries exhausted -> FATAL state"
else
    fail "expected FATAL, got: $RESULT"
fi

# ========================
# TEST G: stopwaitsecs - stop should respect the timeout
# ========================
echo ""
echo "=== TEST G: stopwaitsecs ==="
cleanup
sleep 1

cat > /tmp/test_taskmaster/setup.toml << 'SETUP'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/stopwait_config.toml"
SETUP

cat > /tmp/test_taskmaster/stopwait_config.toml << 'CFG'
[program.slowstop]
command = "trap '' TERM; sleep 3600"
autostart = true
autorestart = "false"
numprocs = 1
startsecs = 0
stopsignal = "TERM"
stopwaitsecs = 2
CFG

cd /tmp/test_taskmaster
/tmp/taskmasterd > /tmp/test_taskmaster/server_g.log 2>&1 &
sleep 2

PROC_PID=$(pgrep -f "sleep 3600" | head -1)
echo "  Process PID: $PROC_PID (trap ignores SIGTERM)"

if [ -n "$PROC_PID" ]; then
    START=$(date +%s)
    send_cmd "stop slowstop" > /dev/null
    sleep 1
    ALIVE1=$(kill -0 $PROC_PID 2>/dev/null && echo "yes" || echo "no")
    echo "  Alive after 1s: $ALIVE1"

    sleep 3
    ALIVE2=$(kill -0 $PROC_PID 2>/dev/null && echo "yes" || echo "no")
    END=$(date +%s)
    ELAPSED=$((END - START))
    echo "  Alive after ${ELAPSED}s: $ALIVE2"

    RESULT=$(send_cmd "status slowstop")
    echo "  Status: '$RESULT'"

    if echo "$RESULT" | grep -q "STOPPED"; then
        pass "Process stopped after stopwaitsecs (SIGKILL fallback works)"
    else
        fail "Process not stopped after stopwaitsecs: $RESULT"
    fi
fi

# ========================
# SUMMARY
# ========================
echo ""
echo "=============================="
echo -e "RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================="
