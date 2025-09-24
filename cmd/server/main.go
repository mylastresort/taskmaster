package main

import (
	"sync"

	"github.com/Archer-01/taskmaster/internal/logger"
	"github.com/Archer-01/taskmaster/internal/manager"
	"github.com/Archer-01/taskmaster/internal/server"
	"github.com/Archer-01/taskmaster/internal/utils"
)

func main() {
	logger.Init()

	setup, err := utils.ParseSetupFile()
	if err != nil {
		logger.Critical(err)
	}

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
