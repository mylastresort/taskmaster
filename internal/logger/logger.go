package logger

import (
	"fmt"
	"log"
	"log/syslog"
	"os"
	"sync"
	"time"
)

const fallbackLogFile = "/var/log/taskmaster.log"

type LogLevel uint8

const (
	InfoLevel LogLevel = iota
	WarnLevel
	ErrorLevel
	CriticalLevel
)

func (lvl LogLevel) String() string {
	switch lvl {
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
	level          LogLevel
	mutex          sync.Mutex
	syslogger      *syslog.Writer
	fallbackLogger *log.Logger
	fallbackFile   *os.File
}

var logger Logger

func Init() {
	syslogger, err := syslog.New(syslog.LOG_INFO, "taskmaster")

	if err != nil {
		f, fileErr := os.OpenFile(fallbackLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if fileErr != nil {
			fmt.Fprintf(os.Stderr, "Warning: syslog and file logging unavailable: syslog=%v file=%v\n", err, fileErr)
		} else {
			fmt.Fprintf(os.Stderr, "Warning: syslog unavailable, falling back to %s\n", fallbackLogFile)
			logger = Logger{
				level:          InfoLevel,
				fallbackLogger: log.New(f, "", 0),
				fallbackFile:   f,
			}
			return
		}
	}

	logger = Logger{
		level:     InfoLevel,
		syslogger: syslogger,
	}
}

func SetLevel(level LogLevel) {
	logger.level = level
}

func (l *Logger) writeSyslog(message string) {
	if l.syslogger != nil {
		l.syslogger.Info(message)
	} else if l.fallbackLogger != nil {
		l.fallbackLogger.Println(message)
	}
}

func (l *Logger) writeSyslogWarn(message string) {
	if l.syslogger != nil {
		l.syslogger.Warning(message)
	} else if l.fallbackLogger != nil {
		l.fallbackLogger.Println(message)
	}
}

func (l *Logger) writeSyslogErr(message string) {
	if l.syslogger != nil {
		l.syslogger.Err(message)
	} else if l.fallbackLogger != nil {
		l.fallbackLogger.Println(message)
	}
}

func (l *Logger) writeSyslogCrit(message string) {
	if l.syslogger != nil {
		l.syslogger.Crit(message)
	} else if l.fallbackLogger != nil {
		l.fallbackLogger.Println(message)
	}
}

func Info(a any) {
	logger.log(InfoLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.writeSyslog(message)
}

func Infof(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(InfoLevel, message)

	logger.writeSyslog(message)
}

func Warn(a any) {
	logger.log(WarnLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.writeSyslogWarn(message)
}

func Warnf(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(WarnLevel, message)

	logger.writeSyslogWarn(message)
}

func Error(a any) {
	logger.log(ErrorLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.writeSyslogErr(message)
}

func Errorf(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(ErrorLevel, message)

	logger.writeSyslogErr(message)
}

func Critical(a any) {
	logger.log(CriticalLevel, a)

	message := fmt.Sprintf("%v", a)
	logger.writeSyslogCrit(message)
}

func Criticalf(format string, a ...any) {
	message := fmt.Sprintf(format, a...)
	logger.log(CriticalLevel, message)

	logger.writeSyslogCrit(message)
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
}
