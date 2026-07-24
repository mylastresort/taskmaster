package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/Archer-01/taskmaster/internal/client"
	"github.com/Archer-01/taskmaster/internal/parser/interpreter"
	"github.com/Archer-01/taskmaster/internal/server"
	"github.com/Archer-01/taskmaster/internal/utils"
	"github.com/chzyer/readline"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

func main() {
	args := os.Args[1:]

	if len(args) >= 2 && args[0] == interpreter.ATTACH {
		if err := runAttach(args[1]); err != nil {
			fmt.Fprintf(os.Stderr, "%s\n", err)
			os.Exit(1)
		}
		return
	}

	setup, err := utils.ParseSetupFile()
	if err != nil {
		utils.Errorf(err.Error())
		return
	}

	c, err := client.NewClient(setup.Socket)
	if err != nil {
		utils.Errorf(err.Error())
		return
	}
	defer c.Close()

	rl, err := readline.New(setup.Prompt)
	if err != nil {
		panic(err)
	}

	defer func() { rl.Close() }()
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

		parsed, err := interpreter.Parse(line)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s\n", err.Error())
		}
		if len(parsed) == 0 {
			continue
		}
		if parsed[0] == interpreter.EXIT {
			return
		}

		if parsed[0] == interpreter.ATTACH {
			if len(parsed) < 2 {
				fmt.Fprintf(os.Stderr, "attach requires a process name\n")
				continue
			}
			err = c.Send(strings.Join(parsed, " "))
			if err != nil {
				utils.Errorf(err.Error())
				continue
			}
			res := c.Read(server.DEL)
			if res.Err != nil {
				utils.Errorf(res.Err.Error())
				continue
			}
			if res.Data == "ATTACH OK" {
				rl.Close()
				handleAttach(c)
				rl, err = readline.New(setup.Prompt)
				if err != nil {
					panic(err)
				}
				rl.Config.EOFPrompt = ""
			} else if res.HasContent() {
				utils.Logf(res.Data)
			}
			continue
		}

		err = c.Send(strings.Join(parsed, " "))
		if err != nil {
			utils.Errorf(err.Error())
		}

		res := c.Read(server.DEL)
		if res.Err != nil {
			utils.Errorf(res.Err.Error())
		} else if res.HasContent() {
			utils.Logf(res.Data)
		}
	}
}

func runAttach(name string) error {
	setup, err := utils.ParseSetupFile()
	if err != nil {
		return err
	}

	c, err := client.NewClient(setup.Socket)
	if err != nil {
		return err
	}
	defer c.Close()

	err = c.Send("attach " + name)
	if err != nil {
		return err
	}

	res := c.Read(server.DEL)
	if res.Err != nil {
		return res.Err
	}
	if res.Data != "ATTACH OK" {
		return fmt.Errorf("%s", res.Data)
	}

	handleAttach(c)
	return nil
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

	stdinStopR, stdinStopW, _ := os.Pipe()
	go func() {
		<-stop
		stdinStopW.Close()
	}()

	go func() {
		defer close(goroutineDone)
		defer stdinStopR.Close()
		buf := make([]byte, 4096)
		stdinFdNum := int32(stdinFd)
		stopFd := int32(stdinStopR.Fd())
		for {
			fds := []unix.PollFd{
				{Fd: stdinFdNum, Events: unix.POLLIN},
				{Fd: stopFd, Events: unix.POLLIN},
			}
			n, err := unix.Poll(fds, -1)
			if err != nil {
				if err == unix.EINTR {
					continue
				}
				return
			}
			if n == 0 {
				continue
			}
			if fds[1].Revents != 0 {
				return
			}
			if fds[0].Revents&(unix.POLLIN|unix.POLLHUP) != 0 {
				nr, rerr := unix.Read(stdinFd, buf)
				if nr > 0 {
					if nr >= 2 && buf[0] == 0x01 && buf[1] == 0x04 {
						c.Socket.Write([]byte{0x01, 0x04})
						close(detach)
						return
					}
					c.Socket.Write(buf[:nr])
				}
				if rerr != nil {
					return
				}
			}
		}
	}()

	go func() {
		tmp := make([]byte, 4096)
		marker := []byte("DETACH OK\r")
		var leftover []byte
		for {
			n, err := c.Socket.Read(tmp)
			if n > 0 {
				leftover = append(leftover, tmp[:n]...)
				idx := bytes.Index(leftover, marker)
				if idx >= 0 {
					if idx > 0 {
						os.Stdout.Write(leftover[:idx])
					}
					close(stop)
					return
				}
				os.Stdout.Write(leftover)
				leftover = leftover[:0]
			}
			if err != nil {
				if len(leftover) > 0 {
					os.Stdout.Write(leftover)
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

	term.Restore(stdinFd, oldState)
	fmt.Fprintf(os.Stderr, "\r\n[Detached.]\r\n")
}
