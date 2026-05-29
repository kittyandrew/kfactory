package main

import (
	"fmt"
	"time"
)

func (r *runner) phasePtyRestartAbandonsTask() error {
	ws, err := r.kfactoryDispatch("wait for instructions")
	if err != nil {
		return err
	}
	time.Sleep(5 * time.Second)
	if _, err := r.cli("kfactory", "tick", ws, "--prompt", "Use the pty_spawn tool to start the bash command 'sleep 30 && echo PTY_RESTART_DONE'. Set notifyOnExit to true. Then stop immediately -- do not call any other tools."); err != nil {
		return err
	}
	time.Sleep(10 * time.Second)
	spawnCount, err := r.notifyOnExitPtySpawnCount(ws)
	if err != nil || spawnCount == 0 {
		return fmt.Errorf("agent did not call pty_spawn count=%d err=%v", spawnCount, err)
	}
	if _, err := command("docker", "restart", r.opencodeContainer); err != nil {
		return err
	}
	if err := r.waitHealth(30 * time.Second); err != nil {
		return err
	}
	time.Sleep(3 * time.Second)
	queue := "/tmp/pty-restart-heal.json"
	log, err := r.ocexec("env", "KFACTORY_RECOVERY_QUEUE="+queue, "opencode-heal", r.db)
	if err != nil {
		return fmt.Errorf("heal failed: %w log=%s", err, log)
	}
	queueJSON, _ := r.ocexec("cat", queue)
	if !jsonArrayContains(queueJSON, ws) {
		return fmt.Errorf("heal queue missing abandoned PTY workspace %s: %s", ws, queueJSON)
	}
	fmt.Println("      ✓ heal detected abandoned PTY workspace")
	return nil
}
