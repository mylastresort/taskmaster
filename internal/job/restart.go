package job

import "sync"

func (j *Job) Restart(wg *sync.WaitGroup, _done chan bool, procId int, count int) error {
	done := make(chan bool, 1)
	defer close(done)
	j.Stop(wg, done, procId, count)
	j.Start(wg, _done, procId, count)
	return nil
}
