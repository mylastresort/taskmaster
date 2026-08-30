package job

import (
	"sync"
	"syscall"
	"time"

	"github.com/Archer-01/taskmaster/internal/logger"
)

// startProcId = -1 means stop all processes
// startProcId >= 0 means stop the process with the given procId
// countProcId is the number of processes to stop, starting from startProcId
func (j *Job) Stop(wg *sync.WaitGroup, _done chan bool, startProcId int, countProcId int) error {
	defer func() { _done <- true }()

	if countProcId > j.NumProcs-1 {
		countProcId = j.NumProcs - 1
	} else if countProcId < 0 {
		countProcId = 1
	}

	logger.Debugf("Stopping job %s, procId = %d, NumProcs = %d, j._NumProcs = %d", j.Name, startProcId, j.NumProcs, j._NumProcs)
	j.mustop.Lock()
	defer j.mustop.Unlock()

	logger.Debugf(
		"procId = %d, NumProcs = %d, j._NumProcs = %d", startProcId, j.NumProcs, j._NumProcs,
	)
	if startProcId >= 0 && startProcId < j.NumProcs {
		for i := startProcId; i < startProcId+countProcId && i < j.NumProcs; i++ {
			logger.Debugf("Stop(): Stopping process %s", j.DisplayName(i))
			<-j.startReady[i]
			logger.Debugf("Stop(): Process %s is ready to stop", j.DisplayName(i))
		}
	} else {
		logger.Debugf("Stop(): Stopping all processes of job %s", j.Name)
		for i := range j.NumProcs {
			<-j.startReady[i]
		}
	}

	_wg := sync.WaitGroup{}
	logger.Debugf("Stop(): All processes of job %s are ready to stop", j.Name)

	st := func(i int) {
		defer _wg.Done()
		logger.Debugf("Stop(): Stopping process %s", j.DisplayName(i))
		if !j._running[i] {
			// Worker inactive, nothing left to signal or wait for.
			j.SetPgid(i, 0)
			j.SetState(STOPPED, i)
			return
		}

		// Keep STOPPING set (don't move to STOPPED here) so the worker observes it and terminates.
		j.SetState(STOPPING, i)

		if j.procAlive(i) {
			logger.Debugf("Stop(): Sending stop signal to process %s", j.DisplayName(i))
			err := syscall.Kill(-j.pgid[i], j.StopSignal)
			logger.Debugf("Stop(): Sent stop signal to process %s", j.DisplayName(i))
			if err != nil && err != syscall.ESRCH {
				logger.Debug(err)
			}

			cur := time.Now().Unix()
			for time.Now().Unix()-cur < int64(j.StopWaitSecs) && j.procAlive(i) {
				time.Sleep(100 * time.Millisecond)
			}

			logger.Debugf("Stop(): Stop wait time elapsed for process %s", j.DisplayName(i))

			if j.procAlive(i) {
				logger.Warnf("Stop(): Sending SIGKILL to process %s", j.DisplayName(i))
				err = syscall.Kill(-j.pgid[i], syscall.SIGKILL)
				logger.Debugf("Stop(): Sent SIGKILL to process %s", j.DisplayName(i))
				if err != nil && err != syscall.ESRCH {
					logger.Debug(err)
				}
			}
		}
		j.SetPgid(i, 0)
	}

	if startProcId >= 0 && startProcId < j.NumProcs {
		for i := startProcId; i < startProcId+countProcId && i < j.NumProcs; i++ {
			logger.Debugf("Stop(): Stopping process %s", j.DisplayName(i))
			_wg.Add(1)
			go st(i)
		}
	} else {
		for i := range j.NumProcs {
			logger.Debugf("Stop(): Stopping process %s", j.DisplayName(i))
			_wg.Add(1)
			go st(i)
		}
	}
	_wg.Wait()

	if startProcId >= 0 && startProcId < j.NumProcs {
		for i := startProcId; i < startProcId+countProcId && i < j.NumProcs; i++ {
			// Don't call cmds[i].Wait() (double Wait deadlocks); wait for the worker and re-kill its current group until it exits.
			for j._running[i] {
				j.sigkillProc(i)
				time.Sleep(100 * time.Millisecond)
				logger.Debugf("Stop(): Waiting for process %s to finish cleanup", j.DisplayName(i))
			}
		}
	} else {
		logger.Debugf("Stop(): Waiting for all processes of job %s to exit", j.Name)
		for i := range j.NumProcs {
			for j._running[i] {
				j.sigkillProc(i)
				time.Sleep(100 * time.Millisecond)
				logger.Debugf("Stop(): Waiting for process %s to finish cleanup", j.DisplayName(i))
			}
		}
	}
	return nil
}

func (j *Job) sigkillProc(i int) {
	pgid := j.pgid[i]
	if pgid == 0 {
		return
	}
	if err := syscall.Kill(-pgid, syscall.SIGKILL); err != nil && err != syscall.ESRCH {
		logger.Debug(err)
	}
}
