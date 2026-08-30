package job

import (
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/Archer-01/taskmaster/internal/logger"
	"github.com/Archer-01/taskmaster/internal/parser/config"
	"github.com/Archer-01/taskmaster/internal/utils"
)

type ChangedState struct {
	shouldRestart    bool
	shouldStop       bool
	shouldStart      bool
	numprocsChanged  int
}

func (j *Job) reread(prog *config.Program) ChangedState {
	state := ChangedState{
		shouldRestart:    false,
		shouldStop:       false,
		shouldStart:      false,
		numprocsChanged:  0,
	}

	if prog.Command != j.Command {
		j.Command = prog.Command
		state.shouldRestart = true
	}

	if prog.Directory != j.Dir {
		j.Dir = prog.Directory
		state.shouldRestart = true
	}

	{
		table := make(map[string]int, len(j.Environment))
		for _, env := range j.Environment {
			table[env] += 1
		}
		for _, env := range prog.Environment {
			table[env] += 1
		}
		for _, c := range table {
			if c != 2 {
				state.shouldRestart = true
				j.Environment = prog.Environment
				break
			}
		}

	}

	if prog.Umask != j.Umask {
		j.Umask = prog.Umask
		state.shouldRestart = true
	}

	if prog.StderrLogFile != j.StderrLogFile {
		j.StderrLogFile = prog.StderrLogFile
		state.shouldRestart = true
	}

	if prog.StdoutLogFile != j.StdoutLogFile {
		j.StdoutLogFile = prog.StdoutLogFile
		state.shouldRestart = true
	}

	if j.Autostart != prog.Autostart {
		j.Autostart = prog.Autostart
		if !j.IsRunning() && prog.Autostart {
			state.shouldStart = true
		} else if j.IsRunning() && !prog.Autostart {
			state.shouldStop = true
		}
	}
	j.ExitCodes = normalizeExitCodes(prog.ExitCodes)
	j.StopWaitSecs = prog.StopWaitSecs
	j.StopSignal = utils.ParseSignal(prog.StopSignal)
	j.Autorestart = prog.Autorestart
	j.StartSecs = prog.StartSecs
	j.StartRetries = prog.StartRetries
	j.Priority = prog.Priority
	j.ProcessName = prog.ProcessName

	if prog.RedirectStderr != j.RedirectStderr {
		j.RedirectStderr = prog.RedirectStderr
		if j.IsRunning() {
			state.shouldRestart = true
		}
	}

	if prog.NumProcs != j.NumProcs {
		state.numprocsChanged = prog.NumProcs - j.NumProcs
		j._NumProcs = prog.NumProcs
	}

	if prog.StartSecs != j.StartSecs {
		j.StartSecs = prog.StartSecs
	}

	return state
}

func (j *Job) Resize(newSize int) {
	l := len(j._running)
	if l > newSize {
		j._running = j._running[:newSize]
		j.State = j.State[:newSize]
		j.cmds = j.cmds[:newSize]
		j.pgid = j.pgid[:newSize]
		j.startReady = j.startReady[:newSize]
		j.startOnce = j.startOnce[:newSize]
		j.startTime = j.startTime[:newSize]
	} else if l < newSize {
		cmds := make([]*exec.Cmd, newSize)
		pgid := make([]int, newSize)
		startReady := make([]chan struct{}, newSize)
		startOnce := make([]sync.Once, newSize)
		states := make([]string, newSize)
		startTime := make([]time.Time, newSize)

		for i := range states {
			states[i] = STOPPED
		}

		running := make([]bool, newSize)

		for i := range running {
			running[i] = false
		}

		copy(startTime, j.startTime)
		copy(cmds, j.cmds)
		copy(pgid, j.pgid)
		copy(startReady, j.startReady)
		copy(startOnce, j.startOnce)
		copy(states, j.State)
		copy(running, j._running)

		j.startTime = startTime
		j.cmds = cmds
		j.pgid = pgid
		j.startReady = startReady
		j.startOnce = startOnce
		j.State = states
		j._running = running
	}
}
func (j *Job) Reload(wg *sync.WaitGroup, _done chan bool, prog *config.Program) error {
	wg.Add(1)
	defer wg.Done()

	stdoutChanged := j.StdoutLogFile != prog.StdoutLogFile
	stderrChanged := j.StderrLogFile != prog.StderrLogFile
	state := j.reread(prog)
	skipedDone := true
	if j.IsRunning() {
		if state.shouldStop {
			skipedDone = false
			go j.Stop(wg, _done, -1, 1)
		} else if state.shouldRestart {
			skipedDone = false
			go j.Restart(wg, _done, -1, 1)
		}
		if state.numprocsChanged > 0 {
			j.NumProcs = j._NumProcs
			j.Resize(j._NumProcs)
			go j.Start(wg, _done, j.NumProcs-state.numprocsChanged, state.numprocsChanged)
			skipedDone = false
		} else if state.numprocsChanged < 0 {
			num := -state.numprocsChanged
			ch := make(chan bool, 1)
			go j.Stop(wg, ch, j.NumProcs+state.numprocsChanged, num)
			go func() {
				<-ch
				logger.Debugf("Reload: resizing job to %d", j._NumProcs)
				j.Resize(j._NumProcs)
				j.NumProcs = j._NumProcs
				logger.Debug("Reload: resize done")
				_done <- true
			}()
			skipedDone = false
		}
	} else if state.shouldStart {
		skipedDone = false
		go j.Start(wg, _done, -1, 1)
	}

	if stdoutChanged {
		j.setLog(j.StdoutLogFile, j.StdoutWriter, os.Stdout)
	}

	if stderrChanged {
		j.setLog(j.StderrLogFile, j.StderrWriter, os.Stderr)
	}

	if skipedDone {
		_done <- true
	}
	return nil
}
