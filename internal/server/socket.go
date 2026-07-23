package server

import (
	"bufio"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Archer-01/taskmaster/internal/logger"
	"github.com/Archer-01/taskmaster/internal/manager"
)

type Socket struct {
	Con net.Conn
	Buf string
	Rd  *bufio.Reader
}

func NewSocket(conn net.Conn) *Socket {
	return &Socket{
		Con: conn,
		Rd:  bufio.NewReader(conn),
	}
}

func (s *Socket) Close() {
	s.Con.Close()
}

func parse(text string) (string, []string, error) {
	args := strings.FieldsFunc(text, func(r rune) bool {
		return strings.ContainsRune(" \t\n\v\f\r", r)
	})
	if len(args) < 2 {
		return args[0], make([]string, 0), nil
	}
	return args[0], args[1:], nil
}

func (_sv *Server) handleConnection(del byte, s *Socket, wg *sync.WaitGroup) {
	wg.Add(1)
	defer wg.Done()
	defer s.Close()

	var er error = nil

	for {
		select {
		case <-_sv.done:
			return
		default:
			if er == io.EOF {
				_sv.sockets <- SocketAction{s, false}
				return
			}

			if er != nil {
				logger.Error(er)
			}

			line, err := s.Rd.ReadString(del)
			if er = err; err != nil {
				time.Sleep(100 * time.Millisecond)
				continue
			}

			er = nil

			size := len(line)
			if size == 0 {
				continue
			}
			if line[size-1] != del {
				s.Buf += line
				continue
			}
			line = s.Buf + line[:size-1]
			s.Buf = ""

			cmd, args, err := parse(line)
			if err != nil {
				s.Con.Write([]byte(err.Error()))
			}

			res := _sv.j.Execute(cmd, args...)

			if res.AttachFd != nil {
				s.Con.Write([]byte("ATTACH OK" + string(del)))
				_sv.handleAttach(s, res.AttachFd)
				_sv.j.Execute(manager.DETACH, args[0])
				s.Con.Write([]byte("DETACH OK" + string(del)))
				continue
			}

			if res.Err != nil {
				s.Con.Write([]byte(res.Err.Error() + string(del)))
			} else {
				s.Con.Write([]byte(res.Data + string(del)))
			}
		}
	}
}

func (_sv *Server) handleAttach(s *Socket, ptyFd *os.File) {
	done := make(chan struct{})
	detach := make(chan struct{})

	go func() {
		defer close(done)
		buf := make([]byte, 4096)
		for {
			n, err := ptyFd.Read(buf)
			if n > 0 {
				_, werr := s.Con.Write(buf[:n])
				if werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	go func() {
		defer close(detach)
		buf := make([]byte, 4096)
		for {
			n, err := s.Con.Read(buf)
			if n > 0 {
				for i := 0; i < n-1; i++ {
					if buf[i] == 0x01 && buf[i+1] == 0x04 {
						return
					}
				}
				ptyFd.Write(buf[:n])
			}
			if err != nil {
				return
			}
		}
	}()

	select {
	case <-done:
	case <-detach:
	}
}
