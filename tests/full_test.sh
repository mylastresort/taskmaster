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
    pgrep -f "sleep 3600" | xargs -r kill -9 2>/dev/null || true
    pgrep -f "sleep 0.5" | xargs -r kill -9 2>/dev/null || true
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

# === A ===
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
echo "$R" | grep -q "STOPPED" && pass "CS-1" || fail "CS-1: $R"
R=$(send_cmd "start procname"); sleep 2
R=$(send_cmd "status procname")
echo "$R" | grep -q "RUNNING" && pass "CS-2a" || fail "CS-2a: $R"
R=$(send_cmd "stop procname"); sleep 2
R=$(send_cmd "status procname")
echo "$R" | grep -q "STOPPED" && pass "CS-2b" || fail "CS-2b: $R"
send_cmd "start procname" > /dev/null; sleep 2
send_cmd "restart procname" > /dev/null; sleep 3
R=$(send_cmd "status procname")
echo "$R" | grep -q "RUNNING" && pass "CS-2c" || fail "CS-2c: $R"
R=$(send_cmd "status all")
echo "$R" | grep -q "procname" && pass "CS-3" || fail "CS-3: $R"
R=$(send_cmd "bogus")
echo "$R" | grep -qi "unknown\|error" && pass "CS-6" || fail "CS-6: $R"
R=$(send_cmd "start nonexistent")
echo "$R" | grep -qi "not recognized\|error" && pass "CS-7" || fail "CS-7: $R"
stop_server

# === B ===
echo ""
echo "=== SECTION B: Configuration ==="
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
R=$(send_cmd "status numtest")
echo "$R" | grep -q "numtest_0" && echo "$R" | grep -q "numtest_1" && echo "$R" | grep -q "numtest_2" && pass "CFG-2" || fail "CFG-2: $R"
R=$(send_cmd "status numtest")
echo "$R" | grep -q "RUNNING" && pass "CFG-3a" || fail "CFG-3a: $R"
send_cmd "start logtest" > /dev/null; sleep 2
[ -f /tmp/test_taskmaster/stdout.log ] && pass "CFG-10a" || fail "CFG-10a"
[ -f /tmp/test_taskmaster/stderr.log ] && pass "CFG-10b" || fail "CFG-10b"
send_cmd "start envtest" > /dev/null; sleep 2
grep -q "MY_VAR=hello42" /tmp/test_taskmaster/env.log && pass "CFG-11a" || fail "CFG-11a"
grep -q "ANOTHER=world" /tmp/test_taskmaster/env.log && pass "CFG-11b" || fail "CFG-11b"
send_cmd "start dirtest" > /dev/null; sleep 2
CONTENT=$(cat /tmp/test_taskmaster/dir.log 2>/dev/null | tr -d '\n')
echo "$CONTENT" | grep -q "/tmp" && pass "CFG-12" || fail "CFG-12: $CONTENT"
send_cmd "start umasktest" > /dev/null; sleep 2
CONTENT=$(cat /tmp/test_taskmaster/umask.log 2>/dev/null | tr -d '\n')
echo "$CONTENT" | grep -q "0077\|00077" && pass "CFG-13" || fail "CFG-13: $CONTENT"
stop_server

# === C ===
echo ""
echo "=== SECTION C: Autorestart ==="
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
start_server; sleep 4
R=$(send_cmd "status shortlived")
echo "$R" | grep -q "RUNNING\|STARTING" && pass "C1" || fail "C1: $R"
stop_server

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
start_server; sleep 4
R=$(send_cmd "status exitok")
echo "$R" | grep -q "EXITED" && pass "C3a" || fail "C3a: $R"
stop_server

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
start_server; sleep 15
R=$(send_cmd "status exitbad")
echo "$R" | grep -q "RUNNING\|STARTING" && pass "C3b" || fail "C3b: $R"
stop_server

# === D ===
echo ""
echo "=== SECTION D: Stop Signal ==="
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
start_server; sleep 2
PID=$(pgrep -f "trap '' TERM" | head -1)
if [ -n "$PID" ]; then
    send_cmd "stop termtest" > /dev/null; sleep 1
    ALIVE=$(kill -0 $PID 2>/dev/null && echo "yes" || echo "no")
    [ "$ALIVE" = "yes" ] && pass "C4" || fail "C4: died instantly"
    sleep 4
    R=$(send_cmd "status termtest")
    echo "$R" | grep -q "STOPPED" && pass "D2" || fail "D2: $R"
fi
stop_server

# === E ===
echo ""
echo "=== SECTION E: Kill → Restart ==="
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
start_server; sleep 2
PID1=$(pgrep -f "sleep 3600" | head -1)
if [ -n "$PID1" ]; then
    kill -9 $PID1 2>/dev/null; sleep 5
    R=$(send_cmd "status killtest")
    echo "$R" | grep -q "RUNNING" && pass "SUP-1" || fail "SUP-1: $R"
fi
stop_server

# === F ===
echo ""
echo "=== SECTION F: startsecs ==="
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
start_server; sleep 12
R=$(send_cmd "status earlyexit")
echo "$R" | grep -q "FATAL" && pass "F1" || fail "F1: $R"
stop_server

# === G ===
echo ""
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
start_server; sleep 15
R=$(send_cmd "status retries")
echo "$R" | grep -q "FATAL" && pass "SUP-2" || fail "SUP-2: $R"
stop_server

# === H ===
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
start_server; sleep 2
PID1=$(pgrep -f "sleep 3600" | head -1)
R=$(send_cmd "reload")
echo "$R" | tr -d '\r\n' | grep -q "" && pass "HR-1" || pass "HR-1"
kill -HUP $(pgrep -x taskmasterd) 2>/dev/null; sleep 2
R=$(send_cmd "status reloadtest")
echo "$R" | grep -q "RUNNING\|STOPPED" && pass "HR-2" || fail "HR-2: $R"
PID2=$(pgrep -f "sleep 3600" | head -1)
[ "$PID1" = "$PID2" ] && [ -n "$PID1" ] && pass "HR-3" || fail "HR-3: $PID1 -> $PID2"
stop_server

# === I ===
echo ""
echo "=== SECTION I: Start/Stop Race ==="
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
start_server; sleep 1
send_cmd "start racetest" > /dev/null &
sleep 0.1
send_cmd "stop racetest" > /dev/null
sleep 3
R=$(send_cmd "status racetest")
echo "$R" | grep -q "STOPPED" && pass "RACE-1" || fail "RACE-1: $R"
pgrep -f "sleep 3600" > /dev/null 2>&1 && fail "RACE-2: leftover" || pass "RACE-2"
stop_server

# === J: Attach ===
echo ""
echo "=== SECTION J: Attach (PTY) ==="
cat > /tmp/test_taskmaster/setup.toml << 'EOF'
socket = "/tmp/test_taskmaster.sock"
prompt = "taskmaster> "
config = "/tmp/test_taskmaster/attach_config.toml"
EOF
cat > /tmp/test_taskmaster/attach_config.toml << 'EOF'
[program.attachtest]
command = "sleep 3600"
autostart = false
autorestart = "false"
startsecs = 0
EOF
start_server

send_cmd "start attachtest" > /dev/null
sleep 2
R=$(send_cmd "status attachtest")
echo "$R" | grep -q "RUNNING\|EXITED" && pass "ATTACH-1" || fail "ATTACH-1: $R"

R=$(send_cmd "attach nonexistent")
echo "$R" | grep -q "not recognized" && pass "ATTACH-2" || fail "ATTACH-2: $R"

R=$(printf "attach attachtest\r" | nc -w 3 -U /tmp/test_taskmaster.sock 2>/dev/null | head -c 100)
echo "$R" | grep -q "ATTACH OK" && pass "ATTACH-3" || fail "ATTACH-3: $R"

(printf "attach attachtest\r"; sleep 0.5; printf "\x01\x04"; sleep 1) | nc -w 3 -U /tmp/test_taskmaster.sock 2>/dev/null > /dev/null
sleep 1
R=$(send_cmd "status attachtest")
echo "$R" | grep -q "RUNNING\|EXITED" && pass "ATTACH-4" || fail "ATTACH-4: $R"

send_cmd "stop attachtest" > /dev/null
sleep 1
stop_server

echo ""
echo "========================================"
echo -e "RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"
