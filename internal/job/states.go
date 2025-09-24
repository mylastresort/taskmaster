package job

import (
	"fmt"
)

const (
	STOPPED  = "STOPPED"
	STARTING = "STARTING"
	RUNNING  = "RUNNING"
	BACKOFF  = "BACKOFF"
	STOPPING = "STOPPING"
	EXITED   = "EXITED"
	FATAL    = "FATAL"
	UNKNOWN  = "UNKNOWN"
)

const (
	AUTORESTART_FALSE      = "false"
	AUTORESTART_UNEXPECTED = "unexpected"
	AUTORESTART_TRUE       = "true"
)

func (j *Job) SetState(state string, procId int) error {
	switch state {
	case STARTING, RUNNING, BACKOFF, STOPPING, EXITED, FATAL, UNKNOWN:
		j.State[procId] = state
	case STOPPED:
		j.State[procId] = STOPPED
		if true {
			j.pgid = 0
		}
	default:
		return fmt.Errorf("invalid state: %s", state)
	}
	return nil
}

func (j *Job) Is(state string, procId int) bool {
	return j.State[procId] == state
}

func (j *Job) HasPgid() bool {
	return j.pgid != 0
}

func (j *Job) SetPgid(num int) {
	j.pgid = num
}

func (j *Job) IsRunning() bool {
	for i := range j.NumProcs {
		if j._running[i] {
			return true
		}
	}
	return false
}
