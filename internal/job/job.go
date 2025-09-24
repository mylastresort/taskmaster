package job

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/Archer-01/taskmaster/internal/logger"
	"github.com/Archer-01/taskmaster/internal/parser/config"
	"github.com/Archer-01/taskmaster/internal/utils"
)

type Job struct {
	Name          string
	Command       string
	cmds          []*exec.Cmd
	Environment   []string
	Dir           string
	Autostart     bool
	StdoutLogFile string
	StderrLogFile string
	Umask         string
	State         []string
	StartSecs     int
	StartRetries  int
	Autorestart   string
	ExitCodes     []int
	StopSignal    syscall.Signal
	StopWaitSecs  int
	_running      []bool
	StdoutWriter  *utils.DynamicWriter
	StderrWriter  *utils.DynamicWriter
	NumProcs      int
	pgid          int
	mustart       sync.Mutex
	mustop        sync.Mutex
}

func NewJob(name string, prog *config.Program) *Job {
	has_zero := false
	exit_codes := prog.ExitCodes
	for exit := range exit_codes {
		if exit == 0 {
			has_zero = true
			break
		}
	}
	if !has_zero {
		exit_codes = append(exit_codes, 0)
	}

	states := make([]string, prog.NumProcs)
	for i := range states {
		states[i] = STOPPED
	}

	running := make([]bool, prog.NumProcs)

	for i := range running {
		running[i] = false
	}

	return &Job{
		Name:          name,
		Command:       prog.Command,
		Dir:           prog.Directory,
		Autostart:     prog.Autostart,
		Environment:   prog.Environment,
		StdoutLogFile: prog.StdoutLogFile,
		StderrLogFile: prog.StderrLogFile,
		Umask:         prog.Umask,
		State:         states,
		StartSecs:     prog.StartSecs,
		StartRetries:  prog.StartRetries,
		Autorestart:   prog.Autorestart,
		ExitCodes:     exit_codes,
		StopSignal:    utils.ParseSignal(prog.StopSignal),
		StopWaitSecs:  prog.StopWaitSecs,
		_running:      running,
		StdoutWriter:  &utils.DynamicWriter{},
		StderrWriter:  &utils.DynamicWriter{},
		NumProcs:      prog.NumProcs,
		cmds:          make([]*exec.Cmd, prog.NumProcs),
		pgid:          0,
	}
}

type WorkerFn = func(j *Job, wg *sync.WaitGroup, _done chan bool) error

func (j *Job) Start(wg *sync.WaitGroup, _done chan bool) error {
	defer func() { _done <- true }()

	j.mustart.Lock()
	done := make(chan bool, j.NumProcs)
	defer close(done)

	for i := range j.NumProcs {
		if j.Is(STOPPING, i) || j._running[i] {
			done <- true
			continue
		}

		j._running[i] = true

		if j.HasPgid() {
			go j.startJobWorker(wg, i, done, j.pgid)
			continue
		}

		go j.startJobWorker(wg, i, done, 0)
		<-done
		done <- true
		if !j.Is(RUNNING, 0) {
			return fmt.Errorf("process could not be running")
		}
		j.pgid = j.cmds[i].Process.Pid
	}

	for range j.NumProcs {
		<-done
	}
	j.mustart.Unlock()
	return nil
}

func (j *Job) startJobWorker(wg *sync.WaitGroup, id int, done chan bool, pgid int) {
	wg.Add(1)
	defer wg.Done()

	cmd_list := []string{
		"sh",
		"-c",
		fmt.Sprintf("umask %v && %v", j.Umask, j.Command),
	}

	cmd := exec.Command(cmd_list[0], cmd_list[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: pgid}

	j.cmds[id] = cmd

	retries := 0
	for {
		j.SetState(STARTING, id)
		err := j.tryStart(id)
		if err != nil {
			logger.Error(err)
			j.SetState(BACKOFF, id)
			retries++
			if j.StartRetries == retries {
				break
			}
			time.Sleep(1 * time.Second)
			continue
		}

		cur_ts := int(time.Now().Unix())
		j.SetState(RUNNING, id)
		done <- true
		state, _ := j.cmds[id].Process.Wait()
		j.cmds[id].ProcessState = state

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
			for exit := range j.ExitCodes {
				if exit == j.cmds[id].ProcessState.ExitCode() {
					break
				}
			}
		}
	}
	if j.Is(BACKOFF, id) {
		j.SetState(FATAL, id)
	} else if j.Is(STOPPING, id) {
		j.SetState(STOPPED, id)
	}
	j._running[id] = false
}

func (j *Job) setLog(file string, writer *utils.DynamicWriter, _default io.Writer) error {
	if file != "" {
		file, err := utils.OpenLogFile(file)
		if err != nil {
			return err
		}

		writer.SetWriter(file)
	} else if _default != nil {
		writer.SetWriter(_default)
	}
	return nil
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
	j.cmds[procId].Stderr = j.StderrWriter

	j.cmds[procId].Env = append(j.Environment, os.Environ()...)
	j.cmds[procId].Dir = j.Dir

	err = j.cmds[procId].Start()
	if err != nil {
		return err
	}

	return nil
}

func (j *Job) Restart(wg *sync.WaitGroup, _done chan bool) error {
	done := make(chan bool, 1)
	defer close(done)
	j.Stop(wg, done)
	j.Start(wg, _done)
	return nil
}

func (j *Job) Stop(wg *sync.WaitGroup, _done chan bool) error {
	defer func() { _done <- true }()
	j.mustop.Lock()

	if j.HasPgid() {
		for i := range j.NumProcs {
			j.SetState(STOPPING, i)
		}
		cur := time.Now().Unix()
		err := syscall.Kill(-j.pgid, syscall.SIGKILL)
		if err != nil {
			return err
		}

		for time.Now().Unix()-cur < int64(j.StopWaitSecs) && j.IsRunning() {
			time.Sleep(100 * time.Millisecond)
		}

		if j.HasPgid() {
			err = syscall.Kill(-j.pgid, j.StopSignal)
			return err
		}

		for j.IsRunning() {
			time.Sleep(100 * time.Millisecond)
		}
	}

	j.SetPgid(0)
	j.mustop.Unlock()
	return nil
}

func (j *Job) Reload(wg *sync.WaitGroup, _done chan bool, prog *config.Program) error {
	wg.Add(1)
	defer wg.Done()

	stdoutChanged := j.StdoutLogFile != prog.StdoutLogFile
	stderrChanged := j.StderrLogFile != prog.StderrLogFile
	shouldRestart := j.reread(prog)
	if shouldRestart && j.IsRunning() {
		go j.Restart(wg, _done)
		return nil
	}

	if stdoutChanged {
		j.setLog(j.StdoutLogFile, j.StdoutWriter, os.Stdout)
	}

	if stderrChanged {
		j.setLog(j.StderrLogFile, j.StderrWriter, os.Stderr)
	}

	_done <- true
	return nil
}

func (j *Job) reread(prog *config.Program) bool {
	shouldRestart := false

	if prog.Command != j.Command {
		j.Command = prog.Command
		shouldRestart = true
	}

	if prog.Directory != j.Dir {
		j.Dir = prog.Directory
		shouldRestart = true
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
				shouldRestart = true
				j.Environment = prog.Environment
				break
			}
		}

	}

	if prog.Umask != j.Umask {
		j.Umask = prog.Umask
		shouldRestart = true
	}

	if prog.StderrLogFile != j.StderrLogFile {
		j.StderrLogFile = prog.StderrLogFile
	}

	if prog.StdoutLogFile != j.StdoutLogFile {
		j.StdoutLogFile = prog.StdoutLogFile
	}

	j.Autostart = prog.Autostart
	j.ExitCodes = prog.ExitCodes
	j.StopWaitSecs = prog.StopWaitSecs
	j.StopSignal = utils.ParseSignal(prog.StopSignal)
	j.Autorestart = prog.Autorestart
	j.StartSecs = prog.StartSecs
	j.StartRetries = prog.StartRetries

	return shouldRestart
}
