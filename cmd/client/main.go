package main

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/Archer-01/taskmaster/internal/client"
	"github.com/Archer-01/taskmaster/internal/parser/interpreter"
	"github.com/Archer-01/taskmaster/internal/server"
	"github.com/Archer-01/taskmaster/internal/utils"
	"github.com/chzyer/readline"
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
