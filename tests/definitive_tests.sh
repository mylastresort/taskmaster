#!/bin/bash
# Definitive taskmaster test suite
# Tests each feature against supervisor documentation

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
echo "=== SECTION A: Control Shell ==="
# ================================================

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
echo "$R" | grep -q "STOPPED" && pass "CS-1: status returns STOPPED for non-started program" || fail "CS-1: got '$R'"

R=$(send_cmd "start procname")
sleep 2
R=$(send_cmd "status procname")
echo "$R" | grep -q "RUNNING" && pass "CS-2a: start works → RUNNING" || fail "CS-2a: got '$R'"

R=$(send_cmd "stop procname")
sleep 2
R=$(send_cmd "status procname")
echo "$R" | grep -q "STOPPED" && pass "CS-2b: stop works → STOPPED" || fail "CS-2b: got '$R'"

send_cmd "start procname" > /dev/null
sleep 2
send_cmd "restart procname" > /dev/null
sleep 3
R=$(send_cmd "status procname")
echo "$R" | grep -q "RUNNING" && pass "CS-2c: restart works → RUNNING" || fail "CS-2c: got '$R'"

R=$(send_cmd "status all")
echo "$R" | grep -q "procname" && pass "CS-3: status all shows programs" || fail "CS-3: got '$R'"

R=$(send_cmd "bogus")
echo "$R" | grep -qi "unknown\|error" && pass "CS-6: invalid command returns error" || fail "CS-6: got '$R'"

R=$(send_cmd "start nonexistent")
echo "$R" | grep -qi "not recognized\|error" && pass "CS-7: non-existent job returns error" || fail "CS-7: got '$R'"

R=$(send_cmd "reload")
[ -z "$R" ] && pass "CS-5: reload accepted (empty response)" || fail "CS-5: got '$R'"

stop_server

# ================================================
echo ""
echo "=== SECTION B: Configuration Options ==="
# ================================================

cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/cfg_config.toml"
EOF

cat > /tmp/test_taskmaster/cfg_config.toml << 'EOF'
[program.numtest]
command = "sleep 3600"
autostart = true
autorestart = "false"
numprocs = 3
startsecs = 0

[program.envtest]
command = "env"
autostart = false
autorestart = "false"
environment = ["MY_VAR=hello42", "ANOTHER=world"]
stdout_logfile = "/tmp/test_taskmaster/env.log"
startsecs = 0

[program.dirtest]
command = "pwd"
autostart = false
autorestart = "false"
directory = "/tmp"
stdout_logfile = "/tmp/test_taskmaster/dir.log"
startsecs = 0

[program.umasktest]
command = "umask"
autostart = false
autorestart = "false"
umask = "0077"
stdout_logfile = "/tmp/test_taskmaster/umask.log"
startsecs = 0

[program.logtest]
command = "sleep 3600"
autostart = false
autorestart = "false"
stdout_logfile = "/tmp/test_taskmaster/stdout.log"
stderr_logfile = "/tmp/test_taskmaster/stderr.log"
startsecs = 0
EOF

start_server

# CFG-2: numprocs
R=$(send_cmd "status numtest")
N0=$(echo "$R" | grep -c "numtest_0")
N1=$(echo "$R" | grep -c "numtest_1")
N2=$(echo "$R" | grep -c "numtest_2")
[ "$N0" -ge 1 ] && [ "$N1" -ge 1 ] && [ "$N2" -ge 1 ] && pass "CFG-2: numprocs=3 shows 3 processes" || fail "CFG-2: got '$R'"

# CFG-3: autostart
R=$(send_cmd "status numtest")
echo "$R" | grep -q "RUNNING" && pass "CFG-3a: autostart=true → running" || fail "CFG-3a: got '$R'"

# CFG-10: stdout/stderr log files
send_cmd "start logtest" > /dev/null
sleep 2
[ -f /tmp/test_taskmaster/stdout.log ] && pass "CFG-10a: stdout_logfile created" || fail "CFG-10a: file not created"
[ -f /tmp/test_taskmaster/stderr.log ] && pass "CFG-10b: stderr_logfile created" || fail "CFG-10b: file not created"

# CFG-11: environment variables
send_cmd "start envtest" > /dev/null
sleep 2
if [ -f /tmp/test_taskmaster/env.log ]; then
    grep -q "MY_VAR=hello42" /tmp/test_taskmaster/env.log && pass "CFG-11a: MY_VAR set" || fail "CFG-11a: MY_VAR not in env"
    grep -q "ANOTHER=world" /tmp/test_taskmaster/env.log && pass "CFG-11b: ANOTHER set" || fail "CFG-11b: ANOTHER not in env"
else
    fail "CFG-11: env.log not created"
fi

# CFG-12: directory
send_cmd "start dirtest" > /dev/null
sleep 2
CONTENT=$(cat /tmp/test_taskmaster/dir.log 2>/dev/null | tr -d '\n')
echo "$CONTENT" | grep -q "/tmp" && pass "CFG-12: working directory is /tmp" || fail "CFG-12: got '$CONTENT'"

# CFG-13: umask
send_cmd "start umasktest" > /dev/null
sleep 2
CONTENT=$(cat /tmp/test_taskmaster/umask.log 2>/dev/null | tr -d '\n')
echo "$CONTENT" | grep -q "0077\|00077" && pass "CFG-13: umask is 0077" || fail "CFG-13: got '$CONTENT'"

stop_server

# ================================================
echo ""
echo "=== SECTION C: Autorestart (Supervisor Spec) ==="
# ================================================
# Per supervisor docs:
#   autorestart only applies to processes that reached RUNNING state
#   Processes exiting before startsecs are handled by startsecs/startretries

# C2 TEST: autorestart=false + process exits before startsecs
echo "--- C2: autorestart=false with fast exit ---"
cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/c2_config.toml"
EOF

cat > /tmp/test_taskmaster/c2_config.toml << 'EOF'
[program.fastexit]
command = "exit 0"
autostart = true
autorestart = "false"
startsecs = 1
startretries = 3
EOF

start_server
sleep 5  # wait for retries to exhaust
R=$(send_cmd "status fastexit")
echo "  autorestart=false, exit before startsecs: '$R'"
# Per supervisor: process that exits before startsecs enters BACKOFF→FATAL
# autorestart=false should mean it does NOT enter retry loop
# But supervisor says: "Even if a process exits with an expected exit code,
# the start will still be considered a failure if the process exits quicker than startsecs"
# So BACKOFF/FATAL is actually expected per supervisor for the startsecs path.
# HOWEVER, autorestart=false means the EXITED→RUNNING autorestart won't happen.
# The issue is: does the BACKOFF→retry happen with autorestart=false?
# In supervisor, BACKOFF is independent of autorestart. The startsecs/startretries
# mechanism handles STARTING state, not autorestart.
# So FATAL is actually correct here per supervisor behavior.
echo "$R" | grep -q "FATAL\|EXITED" && pass "C2: autorestart=false + fast exit → FATAL (supervisor-correct)" || fail "C2: got '$R'"

stop_server

# C1 TEST: autorestart=true + process exits normally (after startsecs)
echo "--- C1: autorestart=true with normal exit ---"
cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/c1_config.toml"
EOF

cat > /tmp/test_taskmaster/c1_config.toml << 'EOF'
[program.shortlived]
command = "sleep 0.5"
autostart = true
autorestart = "true"
startsecs = 0
startretries = 5
EOF

start_server
sleep 4  # let it exit and try to restart a few times
R=$(send_cmd "status shortlived")
echo "  autorestart=true, normal exit (startsecs=0): '$R'"
# Per supervisor: EXITED→RUNNING is automatic when autorestart=true
# Expected: RUNNING or STARTING (continuously restarting)
# Bug C1: exec.Cmd reuse prevents restart → FATAL or BACKOFF
echo "$R" | grep -q "RUNNING\|STARTING" && pass "C1: autorestart=true → process restarted (RUNNING)" || fail "C1: autorestart=true → '$R' (expected RUNNING, exec.Cmd reuse bug)"

stop_server

# C3 TEST: autorestart=unexpected + expected exit → should NOT restart
echo "--- C3a: autorestart=unexpected, expected exit code ---"
cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/c3a_config.toml"
EOF

cat > /tmp/test_taskmaster/c3a_config.toml << 'EOF'
[program.exitok]
command = "exit 0"
autostart = true
autorestart = "unexpected"
startsecs = 0
exitcodes = [0]
startretries = 3
EOF

start_server
sleep 4
R=$(send_cmd "status exitok")
echo "  autorestart=unexpected, exit 0 (expected): '$R'"
# Per supervisor: EXITED state, no restart since exit code is expected
echo "$R" | grep -q "EXITED" && pass "C3a: expected exit → EXITED (no restart)" || fail "C3a: got '$R' (expected EXITED)"

stop_server

# C3b TEST: autorestart=unexpected + unexpected exit → SHOULD restart
echo "--- C3b: autorestart=unexpected, unexpected exit code ---"
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
startretries = 5
EOF

start_server
sleep 4
R=$(send_cmd "status exitbad")
echo "  autorestart=unexpected, exit 42 (unexpected): '$R'"
# Per supervisor: EXITED→RUNNING (restart since 42 not in exitcodes)
echo "$R" | grep -q "RUNNING\|STARTING" && pass "C3b: unexpected exit → restarted" || fail "C3b: got '$R' (expected RUNNING)"

stop_server

# ================================================
echo ""
echo "=== SECTION D: Stop Signal Logic ==="
# ================================================
# Per supervisor: stopsignal sent first, then SIGKILL after stopwaitsecs

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

    # Per supervisor: SIGTERM sent first, process may survive briefly
    # If SIGKILL sent first, process dies instantly
    if [ "$ALIVE" = "yes" ]; then
        pass "C4: Process survived 1s → graceful signal sent first (correct)"
    else
        fail "C4: Process died instantly → SIGKILL sent first (should be stopsignal then SIGKILL)"
    fi

    # Wait for stopwaitsecs and check final state
    sleep 4
    R=$(send_cmd "status termtest")
    echo "$R" | grep -q "STOPPED" && pass "D2: Process STOPPED after stopwaitsecs" || fail "D2: got '$R'"
fi

stop_server

# ================================================
echo ""
echo "=== SECTION E: Kill Process → Restart ==="
# ================================================
# Per supervisor: "When a process is in the EXITED state, it will
# automatically restart unconditionally if autorestart=true"

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
    sleep 5  # give time for restart cycle
    PID2=$(pgrep -f "sleep 3600" | head -1)
    R=$(send_cmd "status killtest")
    echo "  After kill: '$R', new PID: $PID2"
    echo "$R" | grep -q "RUNNING" && pass "SUP-1: killed process restarted → RUNNING" || fail "SUP-1: killed process → '$R' (expected RUNNING)"
fi

stop_server

# ================================================
echo ""
echo "=== SECTION F: startsecs (Supervisor Spec) ==="
# ================================================
# Per supervisor: "Even if a process exits with an 'expected' exit code,
# the start will still be considered a failure if the process exits quicker
# than startsecs."

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
sleep 10
R=$(send_cmd "status earlyexit")
echo "  exit 0 with startsecs=5: '$R'"
# Per supervisor: exit before startsecs = BACKOFF → FATAL (startretries=1)
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

# Test reload command
R=$(send_cmd "reload")
[ -z "$R" ] && pass "HR-1: reload command accepted" || fail "HR-1: got '$R'"

# Test SIGHUP
kill -HUP $(pgrep -d, taskmasterd) 2>/dev/null
sleep 2

R=$(send_cmd "status reloadtest")
echo "$R" | grep -q "RUNNING\|STOPPED" && pass "HR-2: SIGHUP reload — server still responds" || fail "HR-2: got '$R'"

PID2=$(pgrep -f "sleep 3600" | head -1)
echo "  PID after reload: $PID2"
if [ "$PID1" = "$PID2" ] && [ -n "$PID1" ]; then
    pass "HR-3: unchanged process NOT restarted (PID preserved)"
else
    fail "HR-3: PID changed from $PID1 to $PID2 (process was restarted)"
fi

stop_server

# ================================================
echo ""
echo "========================================"
echo -e "RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"
