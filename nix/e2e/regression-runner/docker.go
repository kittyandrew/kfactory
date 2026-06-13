package main

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

func (r *runner) setup() error {
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("docker not found. Run dev-up first")
	}
	out, err := command("docker", "ps", "-q", "--filter", "name=^"+r.clientContainer+"$")
	if err != nil {
		return err
	}
	if strings.TrimSpace(out) == "" {
		return fmt.Errorf("%s not running. Run 'nix run .#dev-up' first", r.clientContainer)
	}
	return nil
}

func (r *runner) cli(args ...string) (string, error) {
	full := append([]string{"exec", "-i", r.clientContainer}, args...)
	return command("docker", full...)
}

func (r *runner) cliShell(script string) (string, error) {
	return r.cli("sh", "-c", script)
}

func (r *runner) cliDetachedShell(script string) (string, error) {
	full := []string{"exec", "-d", r.clientContainer, "sh", "-c", script}
	return command("docker", full...)
}

func (r *runner) ocexec(args ...string) (string, error) {
	full := append([]string{"exec", r.opencodeContainer}, args...)
	return command("docker", full...)
}

func command(name string, args ...string) (string, error) {
	return commandStdin("", name, args...)
}

func commandStdin(stdin, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return out.String(), err
}
