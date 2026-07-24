package config

import (
	"strings"

	"github.com/BurntSushi/toml"
)

type Program struct {
	Command        string   `toml:"command" validate:"required"`
	Autostart      bool     `toml:"autostart" validate:"default=true"`
	NumProcs       int      `toml:"numprocs" validate:"default=1,min=1"`
	Environment    []string `toml:"environment"`
	Directory      string   `toml:"directory"`
	StdoutLogFile  string   `toml:"stdout_logfile"`
	StderrLogFile  string   `toml:"stderr_logfile"`
	Umask          string   `toml:"umask" validate:"default=0022"`
	StartSecs      int      `toml:"startsecs" validate:"default=1,min=0"`
	StartRetries   int      `toml:"startretries" validate:"default=3,min=0"`
	Autorestart    string   `toml:"autorestart" validate:"default=unexpected,enum=false|unexpected|true"`
	StopSignal     string   `toml:"stopsignal" validate:"default=TERM,enum=TERM|HUP|INT|QUIT|KILL|USR1|USR2"`
	StopWaitSecs   int      `toml:"stopwaitsecs" validate:"default=10,min=0"`
	ExitCodes      []int    `toml:"exitcodes"`
	Priority       int      `toml:"priority"`
	RedirectStderr bool     `toml:"redirect_stderr"`
	ProcessName    string   `toml:"process_name"`
}

type Config struct {
	Programs map[string]*Program `toml:"program"`
	User     string              `toml:"user"`
}

func ParseCommand(cmd string) []string {
	return strings.FieldsFunc(cmd, func(r rune) bool {
		return strings.ContainsRune(" \t\n\v\f\r", r)
	})
}

func ParseConfig(file string) (Config, error) {
	var conf Config

	mdata, err := toml.DecodeFile(file, &conf)

	err_msg := Validate(&conf, mdata)
	if err_msg != nil {
		return conf, err_msg
	}

	return conf, err
}
