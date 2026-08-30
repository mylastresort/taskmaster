package main

import (
	"fmt"
	"os"
	"sync"

	"github.com/Archer-01/taskmaster/internal/logger"
	"github.com/Archer-01/taskmaster/internal/manager"
	"github.com/Archer-01/taskmaster/internal/server"
	"github.com/Archer-01/taskmaster/internal/utils"
)

func main() {
	setup, err := utils.ParseSetupFile()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: Cannot read %s: %v\n", utils.CONF, err)
		os.Exit(1)
	}

	logger.Init(setup.LogFile)
	defer logger.Close()

	if setup.Socket == "" {
		setup.Socket = fmt.Sprintf("/tmp/taskmasterd-%d.sock", os.Getpid())
	}
	logger.Infof("Socket: %s", setup.Socket)

	var wg sync.WaitGroup
	defer wg.Wait()

	Manager := manager.NewJobManager(setup.Config, &wg)
	err = Manager.Init()
	if err != nil {
		logger.Critical(err)
	}

	Server := server.NewServer(setup.Socket, Manager)
	err = Server.Init()
	if err != nil {
		logger.Critical(err)
	}

	Manager.InitSignals()
	go Manager.WaitForSignals(&wg)
	defer Manager.StopSignals()

	go Server.Start(&wg)
	defer Server.Stop()

	Manager.Run()
}
