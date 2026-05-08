/*
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Docker primitives shared by every FM-* CAPD e2e reproducer.
// Each FM specifies a fault as a docker container manipulation
// (pause / network disconnect / exec). The helpers below shell
// out to the docker CLI rather than the Docker Go client to
// keep this test package free of additional dependencies — the
// e2e harness already requires a working docker daemon.
//
// dockerPause / dockerUnpause originated in fm2_quorum_loss.go;
// the rest were added when issue #9 brought up the FM-3, FM-13,
// FM-19 reproducers. Prefer this file as the home for any
// docker-CLI helper that more than one FM spec needs.

//go:build e2e

package e2e

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// dockerPause invokes `docker pause <container>...`.
func dockerPause(ctx context.Context, containers ...string) error {
	args := append([]string{"pause"}, containers...)
	cmd := exec.CommandContext(ctx, "docker", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker pause %v: %w (output: %s)", containers, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// dockerUnpause is the inverse of dockerPause. A 30 s timeout
// guards against a slow daemon when many paused processes are
// resumed at once.
func dockerUnpause(ctx context.Context, containers ...string) error {
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	args := append([]string{"unpause"}, containers...)
	cmd := exec.CommandContext(cctx, "docker", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker unpause %v: %w (output: %s)", containers, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// dockerNetworkDisconnect detaches `container` from `network`.
// CAPD provisions every node container on the kind network;
// disconnecting one isolates it from the other CP nodes' etcd
// peer + apiserver traffic.
func dockerNetworkDisconnect(ctx context.Context, network, container string) error {
	cmd := exec.CommandContext(ctx, "docker", "network", "disconnect", network, container)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker network disconnect %s %s: %w (output: %s)", network, container, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// dockerNetworkConnect re-attaches `container` to `network`.
func dockerNetworkConnect(ctx context.Context, network, container string) error {
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, "docker", "network", "connect", network, container)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker network connect %s %s: %w (output: %s)", network, container, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// dockerExec runs `docker exec <container> <argv...>`. Returns
// the combined stdout+stderr.
func dockerExec(ctx context.Context, container string, argv ...string) ([]byte, error) {
	args := append([]string{"exec", container}, argv...)
	cmd := exec.CommandContext(ctx, "docker", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("docker exec %s %v: %w (output: %s)", container, argv, err, strings.TrimSpace(string(out)))
	}
	return out, nil
}
