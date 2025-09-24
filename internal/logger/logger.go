package logger

import (
	"fmt"
	"log/syslog"
	"os"
	"sync"
	"time"

	"github.com/Archer-01/taskmaster/internal/utils"
)

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
	level     LogLevel
	mutex     sync.Mutex
	syslogger *syslog.Writer
}

var logger Logger

func Init() {
	syslogger, err := syslog.New(syslog.LOG_INFO, "taskmaster")

	if err != nil {
		utils.Errorf(err.Error())
		os.Exit(1)
	}

	logger = Logger{
		level:     InfoLevel,
		syslogger: syslogger,
	}
}

func SetLevel(level LogLevel) {
	logger.level = level
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
}
