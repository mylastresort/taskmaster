package job

import (
	"fmt"
	"io"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/Archer-01/taskmaster/internal/parser/config"
	"github.com/Archer-01/taskmaster/internal/utils"
)

func (p *Job) StartCmd(procId int) error {
	if err := p.cmds[procId].Start(); err != nil {
		return err
	}
	p.startTime[procId] = time.Now()
	return nil
}

func (p *Job) Uptime(procId int) time.Duration {
	return time.Since(p.startTime[procId])
}

type Job struct {
	Name           string
	Command        string
	cmds           []*exec.Cmd
	Environment    []string
	Dir            string
	Autostart      bool
	startTime      []time.Time
	StdoutLogFile  string
	StderrLogFile  string
	Umask          string
	State          []string
	StartSecs      int
	StartRetries   int
	Autorestart    string
	ExitCodes      []int
	StopSignal     syscall.Signal
	StopWaitSecs   int
	Priority       int
	RedirectStderr bool
	ProcessName    string
	_running       []bool
	StdoutWriter   *utils.DynamicWriter
	StderrWriter   *utils.DynamicWriter
	NumProcs       int
	_NumProcs      int
	pgid           []int
	startReady     []chan struct{}
	startOnce      []sync.Once
	mustop         sync.Mutex
	// muproc         sync.Mutex
}

func normalizeExitCodes(codes []int) []int {
	for _, exit := range codes {
		if exit == 0 {
			return codes
		}
	}
	return append(codes, 0)
}

func NewJob(name string, prog *config.Program) *Job {
	exit_codes := normalizeExitCodes(prog.ExitCodes)

	states := make([]string, prog.NumProcs)
	for i := range states {
		states[i] = STOPPED
	}

	running := make([]bool, prog.NumProcs)

	for i := range running {
		running[i] = false
	}

	ch := make(chan struct{})
	close(ch)

	return &Job{
		Name:           name,
		Command:        prog.Command,
		Dir:            prog.Directory,
		Autostart:      prog.Autostart,
		Environment:    prog.Environment,
		StdoutLogFile:  prog.StdoutLogFile,
		StderrLogFile:  prog.StderrLogFile,
		Umask:          prog.Umask,
		State:          states,
		StartSecs:      prog.StartSecs,
		StartRetries:   prog.StartRetries,
		Autorestart:    prog.Autorestart,
		ExitCodes:      exit_codes,
		StopSignal:     utils.ParseSignal(prog.StopSignal),
		StopWaitSecs:   prog.StopWaitSecs,
		Priority:       prog.Priority,
		RedirectStderr: prog.RedirectStderr,
		ProcessName:    prog.ProcessName,
		_running:       running,
		StdoutWriter:   &utils.DynamicWriter{},
		StderrWriter:   &utils.DynamicWriter{},
		NumProcs:       prog.NumProcs,
		_NumProcs:      prog.NumProcs,
		cmds:           make([]*exec.Cmd, prog.NumProcs),
		pgid:           make([]int, prog.NumProcs),
		startReady:     make([]chan struct{}, prog.NumProcs),
		startOnce:      make([]sync.Once, prog.NumProcs),
		startTime:      make([]time.Time, prog.NumProcs),
		mustop:         sync.Mutex{},
	}
}

func (j *Job) DisplayName(procId int) string {
	if j.ProcessName != "" {
		return fmt.Sprintf(j.ProcessName, j.Name, procId)
	}
	if j.NumProcs == 1 {
		return j.Name
	}
	return fmt.Sprintf("%s_%d", j.Name, procId)
}

type WorkerFn = func(j *Job, wg *sync.WaitGroup, _done chan bool, procId int, count int) error

func groupAlive(pgid int) bool {
	return pgid > 0 && syscall.Kill(-pgid, 0) == nil
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


