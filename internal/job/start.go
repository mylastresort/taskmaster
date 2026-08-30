package job

import (
	"fmt"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/Archer-01/taskmaster/internal/logger"
)

func (j *Job) closeStartReady(procId int) {
	j.startOnce[procId].Do(func() {
		close(j.startReady[procId])
	})
}

func (j *Job) Start(wg *sync.WaitGroup, _done chan bool, procId int, count int) error {
	logger.Debugf("Starting job %s, procId = %d, NumProcs = %d, j._NumProcs = %d", j.Name, procId, j.NumProcs, j._NumProcs)
	defer func() { _done <- true }()

	j.mustop.Lock()
	defer j.mustop.Unlock()

	st := func(i int) {
		j.startReady[i] = make(chan struct{})
		j.startOnce[i] = sync.Once{}
		if j.Is(STOPPING, i) || j._running[i] {
			return
		}

		j._running[i] = true

		if j.HasPgid(i) {
			pgid := j.pgid[i]
			if !groupAlive(pgid) {
				pgid = 0
				j.pgid[i] = 0
			}
			go j.startJobWorker(wg, i, pgid)
			return
		}

		go j.startJobWorker(wg, i, 0)
	}

	logger.Debugf("Starting job %s, procId = %d, NumProcs = %d, j._NumProcs = %d", j.Name, procId, j.NumProcs, j._NumProcs)
	if procId >= 0 && procId < j.NumProcs {
		for i := procId; i < procId+count && i < j.NumProcs; i++ {
			logger.Infof("Starting process %s", j.DisplayName(i))
			st(i)
		}
	} else {
		logger.Infof("Starting all processes of job %s", j.Name)
		for i := range j.NumProcs {
			st(i)
		}
	}

	if procId >= 0 && procId < j.NumProcs {
		<-j.startReady[procId]
	} else {
		for i := range j.NumProcs {
			<-j.startReady[i]
		}
	}
	return nil
}

func (j *Job) startJobWorker(wg *sync.WaitGroup, id int, pgid int) {
	wg.Add(1)
	defer func() {
		j._running[id] = false
	}()
	defer wg.Done()
	defer j.closeStartReady(id)

	retries := 0
	for {
		if j.Is(STOPPING, id) {
			break
		}

		usePgid := pgid
		if usePgid != 0 && !groupAlive(usePgid) {
			usePgid = 0
		}
		if j.cmds[id] != nil && j.cmds[id].Process != nil {
			usePgid = 0
		}

		cmd := exec.Command("sh", "-c", fmt.Sprintf("umask %v && %v", j.Umask, j.Command))
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: usePgid}
		j.cmds[id] = cmd

		j.SetState(STARTING, id)
		err := j.tryStart(id)
		if err != nil {
			logger.Debug(err)
			j.SetState(BACKOFF, id)
			j.closeStartReady(id)
			retries++
			if j.StartRetries == retries {
				break
			}
			time.Sleep(1 * time.Second)
			continue
		}

		cur_ts := int(time.Now().Unix())
		if usePgid == 0 && j.cmds[id].Process != nil {
			j.pgid[id], _ = syscall.Getpgid(j.cmds[id].Process.Pid)
		}
		j.closeStartReady(id)
		_done := make(chan bool, 1)
		__done := false
		a := func() {
			defer wg.Done()
			err = j.cmds[id].Wait()
			__done = true
			if err != nil {
				logger.Debug(err)
			}
			_done <- true
		}
		wg.Add(1)
		go a()
		b := func() {
			defer wg.Done()
			tick := time.NewTicker(100 * time.Millisecond)
			defer tick.Stop()
			for range tick.C {
				if __done {
					return
				}
				if int(time.Now().Unix())-cur_ts >= j.StartSecs {
					j.SetState(RUNNING, id)
				} else if j.Is(RUNNING, id) {
					j.SetState(STARTING, id)
				}
			}
		}
		wg.Add(1)
		go b()
		<-_done

		if j.Is(STOPPING, id) {
			break
		} else if int(time.Now().Unix())-cur_ts < j.StartSecs {
			j.SetState(BACKOFF, id)
			retries++
			if j.StartRetries == retries {
				break
			}
			time.Sleep(1 * time.Second)
			continue
		}

		j.SetState(EXITED, id)
		retries = 0
		if j.Autorestart == AUTORESTART_FALSE {
			break
		}
		if j.Autorestart == AUTORESTART_UNEXPECTED {
			expected := false
			exitCode := -1
			if j.cmds[id].ProcessState != nil {
				exitCode = j.cmds[id].ProcessState.ExitCode()
			}
			for _, exit := range j.ExitCodes {
				if exit == exitCode {
					expected = true
					break
				}
			}
			if expected {
				logger.Debugf("Process %s exited with expected exit code %d, not restarting", j.DisplayName(id), exitCode)
				break
			} else {
				logger.Debugf("Process %s exited with unexpected exit code %d, restarting", j.DisplayName(id), exitCode)
			}
		}
	}
	if j.Is(BACKOFF, id) {
		j.SetState(FATAL, id)
	} else if j.Is(STOPPING, id) {
		j.SetState(STOPPED, id)
	}
}

func (j *Job) tryStart(procId int) error {
	err := j.setLog(j.StdoutLogFile, j.StdoutWriter, os.Stdout)
	if err != nil {
		return err
	}

	err = j.setLog(j.StderrLogFile, j.StderrWriter, os.Stderr)
	if err != nil {
		return err
	}

	j.cmds[procId].Stdout = j.StdoutWriter
	if j.RedirectStderr {
		j.cmds[procId].Stderr = j.StdoutWriter
	} else {
		j.cmds[procId].Stderr = j.StderrWriter
	}

	j.cmds[procId].Env = append(j.Environment, os.Environ()...)
	j.cmds[procId].Dir = j.Dir

	err = j.StartCmd(procId)
	if err != nil {
		return err
	}

	return nil
}
