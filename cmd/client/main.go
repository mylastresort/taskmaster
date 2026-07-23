package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"
	"syscall"
	"time"

	"github.com/Archer-01/taskmaster/internal/client"
	"github.com/Archer-01/taskmaster/internal/parser/interpreter"
	"github.com/Archer-01/taskmaster/internal/server"
	"github.com/Archer-01/taskmaster/internal/utils"
	"github.com/chzyer/readline"
	"golang.org/x/term"
)

func main() {
	setup, err := utils.ParseSetupFile()
	if err != nil {
		utils.Errorf(err.Error())
		return
	}

	client, err := client.NewClient(setup.Socket)
	if err != nil {
		utils.Errorf(err.Error())
		return
	}
	defer client.Close()

	rl, err := readline.New(setup.Prompt)
	if err != nil {
		panic(err)
	}

	defer rl.Close()
	rl.Config.EOFPrompt = ""

	for {
		line, err := rl.Readline()
		if err == io.EOF {
			return
		}
		if err == readline.ErrInterrupt {
			continue
		}
		if err != nil {
			break
		}

		if line == "" {
			continue
		}

		args, err := interpreter.Parse(line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s\n", err.Error())
		}
		if len(args) == 0 {
			continue
		}
		if args[0] == interpreter.EXIT {
			return
		}

		if args[0] == interpreter.ATTACH {
			if len(args) < 2 {
				fmt.Fprintf(os.Stderr, "attach requires a process name\n")
				continue
			}
			err = client.Send(strings.Join(args, " "))
			if err != nil {
				utils.Errorf(err.Error())
				continue
			}
			res := client.Read(server.DEL)
			if res.Err != nil {
				utils.Errorf(res.Err.Error())
				continue
			}
		if res.Data == "ATTACH OK" {
			handleAttach(client)
			} else if res.HasContent() {
				utils.Logf(res.Data)
			}
			continue
		}

		err = client.Send(strings.Join(args, " "))
		if err != nil {
			utils.Errorf(err.Error())
		}

		res := client.Read(server.DEL)
		if res.Err != nil {
			utils.Errorf(res.Err.Error())
		} else if res.HasContent() {
			utils.Logf(res.Data)
		}
	}
}

func handleAttach(c *client.Client) {
	stdinFd := int(os.Stdin.Fd())

	oldState, err := term.MakeRaw(stdinFd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to enter raw mode: %v\n", err)
		return
	}

	fmt.Fprintf(os.Stderr, "\r\n[Attached to process. Press Ctrl+A then D to detach.]\r\n")

	stop := make(chan struct{})
	detach := make(chan struct{})
	goroutineDone := make(chan struct{})

	oldflags, _, _ := syscall.Syscall(syscall.SYS_FCNTL, uintptr(stdinFd), syscall.F_GETFL, 0)
	syscall.Syscall(syscall.SYS_FCNTL, uintptr(stdinFd), syscall.F_SETFL, oldflags|syscall.O_NONBLOCK)

	go func() {
		defer close(goroutineDone)
		buf := make([]byte, 4096)
		for {
			select {
			case <-stop:
				return
			default:
			}
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				if n >= 2 && buf[0] == 0x01 && buf[1] == 0x04 {
					c.Socket.Write([]byte{0x01, 0x04})
					close(detach)
					return
				}
				c.Socket.Write(buf[:n])
			}
			if err != nil {
				time.Sleep(time.Millisecond)
			}
		}
	}()

	go func() {
		var buf []byte
		tmp := make([]byte, 4096)
		for {
			select {
			case <-stop:
				return
			default:
			}
			n, err := c.Rd.Read(tmp)
			if n > 0 {
				buf = append(buf, tmp[:n]...)
				for {
					idx := bytes.Index(buf, []byte("DETACH OK\r"))
					if idx < 0 {
						break
					}
					if idx > 0 {
						os.Stdout.Write(buf[:idx])
					}
					close(stop)
					return
				}
				if len(buf) > 0 && !bytes.Contains(buf, []byte("DETACH")) {
					os.Stdout.Write(buf)
					buf = nil
				}
			}
			if err != nil {
				if len(buf) > 0 {
					os.Stdout.Write(buf)
				}
				close(stop)
				return
			}
		}
	}()

	select {
	case <-detach:
	case <-stop:
	}

	<-goroutineDone

	syscall.Syscall(syscall.SYS_FCNTL, uintptr(stdinFd), syscall.F_SETFL, oldflags)
	term.Restore(stdinFd, oldState)
	fmt.Fprintf(os.Stderr, "\r\n[Detached.]\r\n")
}
