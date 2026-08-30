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
			j.pgid[procId] = 0
		}
	default:
		return fmt.Errorf("invalid state: %s", state)
	}
	return nil
}

func (j *Job) Is(state string, procId int) bool {
	return j.State[procId] == state
}

func (j *Job) HasPgid(procId int) bool {
	return j.pgid[procId] != 0
}

func (j *Job) SetPgid(procId int, num int) {
	j.pgid[procId] = num
}

func (j *Job) IsRunning() bool {
	for i := range j.NumProcs {
		if j._running[i] {
			return true
		}
	}
	return false
}

func (j *Job) isRunningProc(procId int) bool {
	return j._running[procId]
}

func (j *Job) procAlive(id int) bool {
	return j._running[id] && j.HasPgid(id) && groupAlive(j.pgid[id])
}
