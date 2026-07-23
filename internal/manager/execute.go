package manager

import (
	"fmt"
	"os"
)

const (
	STATUS = "status"
)

type Response struct {
	Data     string
	Err      error
	AttachFd *os.File
}

func NewResponse() *Response {
	return &Response{
		Data: "",
		Err:  nil,
	}
}

func NewResponseWithBody(data string) *Response {
	return &Response{
		Data: data,
		Err:  nil,
	}
}

func BadRequest(err error) *Response {
	return &Response{
		Data: "",
		Err:  err,
	}
}

func NewAttachResponse(fd *os.File) *Response {
	return &Response{
		AttachFd: fd,
	}
}

func (r *Response) HasContent() bool {
	return r.Data != ""
}

func (m *JobManager) Execute(action string, args ...string) *Response {
	done := make(chan bool, 1)
	defer close(done)

	data := make(chan string, 1)
	defer close(data)

	switch action {
	case QUIT, RELOAD, START, STOP, RESTART:
		m.actions <- Action{Type: action, Done: done, Data: data, Args: args}
		success := <-done
		if success {
			return NewResponse()
		} else {
			return BadRequest(fmt.Errorf(<-data))
		}

	case STATUS:
		m.actions <- Action{Type: action, Done: done, Data: data, Args: args}
		success := <-done
		if success {
			return NewResponseWithBody(<-data)
		} else {
			return BadRequest(fmt.Errorf(<-data))
		}

	case ATTACH:
		if len(args) != 1 {
			return BadRequest(fmt.Errorf("attach requires 1 argument"))
		}
		fd, err := m.AttachJob(args[0])
		if err != nil {
			return BadRequest(err)
		}
		return NewAttachResponse(fd)

	case DETACH:
		if len(args) != 1 {
			return NewResponse()
		}
		m.DetachJob(args[0])
		return NewResponse()
	}
	return BadRequest(fmt.Errorf("%s Unknown command", action))
}
