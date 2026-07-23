package interpreter

import (
	"fmt"
	"strings"
)

const (
	RELOAD  = "reload"
	RESTART = "restart"
	START   = "start"
	STATUS  = "status"
	STOP    = "stop"
	QUIT    = "quit"
	EXIT    = "exit"
	ATTACH  = "attach"
)

func Parse(line string) ([]string, error) {
	args := strings.Split(line, " ")

	if len(args) == 0 {
		return make([]string, 0), nil
	}

	switch args[0] {
	case RESTART, START, STATUS, STOP, ATTACH:
		return args, nil

	case RELOAD, QUIT, EXIT:
		if len(args) != 1 {
			return nil, fmt.Errorf("%s must not take arguments", args[0])
		}
		return args, nil

	default:
		return nil, fmt.Errorf("*** Unknown syntax: %v", args[0])
	}
}
