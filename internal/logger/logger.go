package logger

import (
	"fmt"
	"log/syslog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type LogLevel uint8

const (
	DebugLevel LogLevel = iota
	InfoLevel
	WarnLevel
	ErrorLevel
	CriticalLevel
)

func (lvl LogLevel) String() string {
	switch lvl {
	case DebugLevel:
		return "DBUG"
	case InfoLevel:
		return "INFO"
	case WarnLevel:
		return "WARN"
	case ErrorLevel:
		return "ERRO"
	case CriticalLevel:
		return "CRIT"
	default:
		return "UNKNOWN"
	}
}

type Logger struct {
	level     LogLevel
	mutex     sync.Mutex
	syslogger *syslog.Writer
	file      *os.File
}

var logger Logger

func Init(logfile string) {
	syslogger, err := syslog.New(syslog.LOG_INFO, "taskmaster")

	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR: syslog unavailable. To fix this, configure a syslog log driver in Docker:")
		fmt.Fprintln(os.Stderr, "  compose.yaml:  logging:\n                  driver: syslog\n                  options:\n                    syslog-address: \"unix:///dev/log\"\n                    tag: \"taskmaster\"")
		fmt.Fprintln(os.Stderr, "  or run with:    docker run --log-driver=syslog --log-opt syslog-address=unix:///dev/log ...")
		fmt.Fprintln(os.Stderr, "  or set as default in /etc/docker/daemon.json: { \"log-driver\": \"syslog\" }")
		fmt.Fprintln(os.Stderr, "Original error:", err)
		os.Exit(1)
	}

	level := InfoLevel
	if lvl, ok := ParseLevel(os.Getenv("LOG_LEVEL")); ok {
		level = lvl
	}

	var file *os.File

	if logfile != "" {
		if dir := filepath.Dir(logfile); dir != "." {
			if err := os.Mkdir(dir, 0755); err != nil {
				fmt.Fprintf(os.Stderr, "ERROR: CAnnot create logfile directory %q: %v\n", dir, err)
				os.Exit(1)
			}
		}

		file, err = os.OpenFile(logfile, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0644)

		if err != nil {
			fmt.Fprintf(os.Stderr, "ERROR: Cannot open logfile %q: %v\n", logfile, err)
			os.Exit(1)
		}
	}

	logger = Logger{
		level:     level,
		syslogger: syslogger,
		file:      file,
	}
}

func Close() {
	logger.mutex.Lock()
	defer logger.mutex.Unlock()

	if logger.file != nil {
		logger.file.Close()
		logger.file = nil
	}
}

func ParseLevel(name string) (LogLevel, bool) {
	switch strings.ToUpper(strings.TrimSpace(name)) {
	case "DEBUG":
		return DebugLevel, true
	case "INFO":
		return InfoLevel, true
	case "WARN", "WARNING":
		return WarnLevel, true
	case "ERROR":
		return ErrorLevel, true
	case "CRITICAL":
		return CriticalLevel, true
	default:
		return InfoLevel, false
	}
}

func SetLevel(level LogLevel) {
	logger.level = level
}

func Debug(a any) {
	logger.log(DebugLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.syslogger.Debug(message)
}

func Debugf(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(DebugLevel, message)

	logger.syslogger.Debug(message)
}

func Info(a any) {
	logger.log(InfoLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.syslogger.Info(message)
}

func Infof(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(InfoLevel, message)

	logger.syslogger.Info(message)
}

func Warn(a any) {
	logger.log(WarnLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.syslogger.Warning(message)
}

func Warnf(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(WarnLevel, message)

	logger.syslogger.Warning(message)
}

func Error(a any) {
	logger.log(ErrorLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.syslogger.Err(message)
}

func Errorf(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(ErrorLevel, message)

	logger.syslogger.Err(message)
}

func Critical(a any) {
	logger.log(CriticalLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.syslogger.Crit(message)
}

func Criticalf(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(CriticalLevel, message)

	logger.syslogger.Crit(message)
}

func (l *Logger) log(level LogLevel, a any) {
	if level < l.level {
		return
	}

	date := time.Now().Format("2006-01-02 15:04:05,000")
	message := fmt.Sprintf("%s %s %s", date, level, a)

	l.mutex.Lock()
	defer l.mutex.Unlock()

	fmt.Println(message)

	if l.file != nil {
		fmt.Fprintln(l.file, message)
	}
}
