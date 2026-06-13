package main

import (
	"fmt"
	"os"
)

func main() {
	r := runner{
		clientContainer:   getenv("CLI_CONTAINER", "kfactory-client"),
		opencodeContainer: getenv("OPENCODE_CONTAINER", "kfactory-opencode"),
		ntfyPort:          getenv("NTFY_PORT", "8080"),
		ntfyTopic:         getenv("NTFY_TOPIC", "kfactory-regression"),
		repo:              "file:///srv/test-repo.git",
		token:             "regression-fake-bearer",
		db:                "/root/.local/share/opencode/opencode.db",
	}
	r.opencodeBase = "http://" + r.opencodeContainer + ":4096"
	r.ntfyInternal = "http://kfactory-ntfy:80"
	r.ntfyURL = "http://localhost:" + r.ntfyPort

	if err := r.run(); err != nil {
		fmt.Fprintf(os.Stderr, "\n❌ %v\n", err)
		os.Exit(1)
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func (r *runner) run() error {
	if err := r.setup(); err != nil {
		return err
	}
	fmt.Println()
	fmt.Println("========================================================")
	fmt.Println(" kfactory regression validation")
	fmt.Println("========================================================")

	// @TODO: - Jun 12, 2026 the environment ships no LLM provider, so
	// phases needing real assistant turns / model tool calls don't exist
	// yet: /loop sentinel termination, ntfy permission.asked, ntfy
	// PTY-pending false-idle suppression, and PTY-restart abandoned-task
	// heal. Add them here once a fake provider lands; until then their
	// contracts are covered by plugins/*/test, nix/unit/opencode/, and
	// the nix/replay fixtures.
	phases := []struct {
		name string
		fn   func() error
	}{
		{"[1] pre-check", r.phasePrecheck},
		{"[2] dispatch three workspaces", r.phaseDispatch},
		{"[3] list workspaces", r.phaseList},
		{"[3b] branch enrichment", r.phaseListBranch},
		{"[4] attach reference ordering", r.phaseAttachResolve},
		{"[4b] session isolation", r.phaseSessionIsolation},
		{"[4c] TUI-shaped session list", r.phaseListByProject},
		{"[4d] sync/start workspace status", r.phaseSyncStartWorkspace},
		{"[4e] SSE live events", r.phaseSSELiveEvents},
		{"[5] ntfy idle body", r.phaseNtfyIdle},
		{"[7] scheduled tick create-on-miss", r.phaseTickCreateOnMiss},
		{"[8] scheduled tick modes", r.phaseTickModesExisting},
		{"[8b] scheduled tick concurrent first-run", r.phaseTickConcurrentFirstRun},
		{"[9] heal + recovery", r.phaseRecovery},
	}
	for _, phase := range phases {
		if err := r.runPhase(phase.name, phase.fn); err != nil {
			return err
		}
	}
	fmt.Println()
	fmt.Println("========================================================")
	fmt.Println(" Done.")
	fmt.Printf(" ntfy UI:  %s/%s\n", r.ntfyURL, r.ntfyTopic)
	fmt.Println("========================================================")
	return nil
}

func (r *runner) runPhase(name string, fn func() error) error {
	fmt.Println()
	fmt.Println(name + "...")
	if err := fn(); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}
