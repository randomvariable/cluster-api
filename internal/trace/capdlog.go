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

package trace

import (
	"bufio"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"strconv"
	"strings"
	"time"
)

// LoadCAPDLogs translates structured CAPD controller-manager JSON lines
// into the TraceRecord shape consumed by the existing formal checkers.
func LoadCAPDLogs(r io.Reader) ([]TraceRecord, error) {
	out := make([]TraceRecord, 0, 256)
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}

		var raw map[string]any
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			return out, fmt.Errorf("line %d: decode capd log json: %w", lineNo, err)
		}

		rec, keep, err := translateCAPDLog(raw, lineNo)
		if err != nil {
			return out, fmt.Errorf("line %d: %w", lineNo, err)
		}
		if !keep {
			continue
		}
		out = append(out, rec)
	}
	if err := sc.Err(); err != nil {
		return out, fmt.Errorf("scan capd logs: %w", err)
	}
	return out, nil
}

func translateCAPDLog(raw map[string]any, lineNo int) (TraceRecord, bool, error) {
	msg, ok := capdString(raw, "msg", "message")
	if !ok || msg == "" {
		return TraceRecord{}, false, nil
	}

	rec := TraceRecord{
		Seq:  uint64(lineNo),
		Time: capdTime(raw),
		Vars: map[string]any{},
	}

	switch {
	case strings.Contains(msg, "Bootstrap etcd voters"):
		voters, ok := capdStrings(raw, "voters")
		if !ok || len(voters) == 0 {
			return TraceRecord{}, false, fmt.Errorf("Bootstrap etcd voters missing voters")
		}
		enc := make([]string, 0, len(voters))
		for _, v := range voters {
			enc = append(enc, strconv.FormatUint(capdStableID(v), 10))
		}
		rec.Spec = SpecEtcdMembership
		rec.Action = "Bootstrap"
		rec.Vars["voters"] = enc
		return rec, true, nil

	case strings.Contains(msg, "Adding etcd member"):
		node, ok := capdString(raw, "node", "member", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Adding etcd member missing node")
		}
		rec.Spec = SpecEtcdMembership
		rec.Action = "AddLearner"
		rec.Subject = node
		rec.Vars["id"] = capdStableID(node)
		return rec, true, nil

	case strings.Contains(msg, "Observed learner progress"):
		node, ok := capdString(raw, "node", "member", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Observed learner progress missing node")
		}
		progress, ok := capdString(raw, "progress")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Observed learner progress missing progress")
		}
		rec.Spec = SpecEtcdMembership
		rec.Action = "ObserveLearnerProgress"
		rec.Subject = node
		rec.Vars["id"] = capdStableID(node)
		rec.Vars["progress"] = progress
		return rec, true, nil

	case strings.Contains(msg, "Promoting learner etcd member"):
		node, ok := capdString(raw, "node", "member", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Promoting learner etcd member missing node")
		}
		rec.Spec = SpecEtcdMembership
		rec.Action = "PromoteLearner"
		rec.Subject = node
		rec.Vars["id"] = capdStableID(node)
		return rec, true, nil

	case strings.Contains(msg, "Removing etcd member"):
		node, ok := capdString(raw, "node", "member", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Removing etcd member missing node")
		}
		rec.Spec = SpecEtcdMembership
		rec.Action = "RemoveMember"
		rec.Subject = node
		rec.Vars["id"] = capdStableID(node)
		return rec, true, nil

	case strings.Contains(msg, "Elected etcd leader"):
		candidate, ok := capdString(raw, "candidate", "node", "member", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Elected etcd leader missing candidate")
		}
		term, ok := capdUint64(raw, "term")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Elected etcd leader missing term")
		}
		rec.Spec = SpecEtcdMembership
		rec.Action = "ElectLeader"
		rec.Subject = candidate
		rec.Vars["candidate"] = capdStableID(candidate)
		rec.Vars["term"] = term
		return rec, true, nil

	case strings.Contains(msg, "Starting kubeadm join"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Starting kubeadm join missing machine")
		}
		rec.Spec = SpecKubeadmJoin
		rec.Action = "BeginJoin"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Preflight checks passed"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Preflight checks passed missing machine")
		}
		rec.Spec = SpecKubeadmJoin
		rec.Action = "PreflightPass"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Kubelet started"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Kubelet started missing machine")
		}
		rec.Spec = SpecKubeadmJoin
		rec.Action = "KubeletStarted"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Added learner to etcd"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Added learner to etcd missing machine")
		}
		rec.Spec = SpecKubeadmJoin
		rec.Action = "EtcdAddLearnerSucceeded"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Etcd quorum reached"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Etcd quorum reached missing machine")
		}
		rec.Spec = SpecKubeadmJoin
		rec.Action = "EtcdQuorumReady"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Marked control plane node ready"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Marked control plane node ready missing machine")
		}
		rec.Spec = SpecKubeadmJoin
		rec.Action = "MarkReady"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "kubeadm join failed"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("kubeadm join failed missing machine")
		}
		reason, ok := capdString(raw, "reason")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("kubeadm join failed missing reason")
		}
		rec.Spec = SpecKubeadmJoin
		rec.Action = "JoinFailedAt"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		rec.Vars["reason"] = reason
		return rec, true, nil

	case strings.Contains(msg, "Discovered control plane machine"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Discovered control plane machine missing machine")
		}
		rec.Spec = SpecKCPReconcile
		rec.Action = "AddMachine"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Resolved machine nodeRef"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Resolved machine nodeRef missing machine")
		}
		rec.Spec = SpecKCPReconcile
		rec.Action = "ResolveNodeRef"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Requested remediation"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Requested remediation missing machine")
		}
		rec.Spec = SpecKCPReconcile
		rec.Action = "RequestRemediation"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Evaluated remediation safety"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Evaluated remediation safety missing machine")
		}
		rec.Spec = SpecKCPReconcile
		rec.Action = "EvaluateCanSafelyRemediate"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Completed remediation"):
		machine, ok := capdString(raw, "machine", "subject", "name")
		if !ok {
			return TraceRecord{}, false, fmt.Errorf("Completed remediation missing machine")
		}
		rec.Spec = SpecKCPReconcile
		rec.Action = "CompleteRemediation"
		rec.Subject = machine
		rec.Vars["machine"] = capdStableID(machine)
		return rec, true, nil

	case strings.Contains(msg, "Derived machine health condition"):
		v1, ok1 := capdString(raw, "v1beta1MessageTag")
		v2, ok2 := capdString(raw, "v1beta2MessageTag")
		if !ok1 || !ok2 {
			return TraceRecord{}, false, fmt.Errorf("Derived machine health condition missing v1beta1MessageTag or v1beta2MessageTag")
		}
		rec.Spec = SpecMachineHealthCheck
		rec.Action = "DeriveCondition"
		rec.Subject, _ = capdString(raw, "machine", "subject", "name")
		rec.Vars["v1beta1MessageTag"] = v1
		rec.Vars["v1beta2MessageTag"] = v2
		return rec, true, nil
	}

	return TraceRecord{}, false, nil
}

func capdString(raw map[string]any, keys ...string) (string, bool) {
	for _, key := range keys {
		v, ok := raw[key]
		if !ok {
			continue
		}
		if s, ok := v.(string); ok && s != "" {
			return s, true
		}
	}
	return "", false
}

func capdStrings(raw map[string]any, key string) ([]string, bool) {
	v, ok := raw[key]
	if !ok {
		return nil, false
	}
	a, ok := v.([]any)
	if !ok {
		return nil, false
	}
	out := make([]string, 0, len(a))
	for _, item := range a {
		s, ok := item.(string)
		if !ok || s == "" {
			return nil, false
		}
		out = append(out, s)
	}
	return out, true
}

func capdUint64(raw map[string]any, keys ...string) (uint64, bool) {
	for _, key := range keys {
		v, ok := raw[key]
		if !ok {
			continue
		}
		switch x := v.(type) {
		case float64:
			return uint64(x), true
		case int:
			return uint64(x), true
		case int64:
			return uint64(x), true
		case uint64:
			return x, true
		case json.Number:
			n, err := x.Int64()
			if err == nil {
				return uint64(n), true
			}
		case string:
			n, err := strconv.ParseUint(x, 10, 64)
			if err == nil {
				return n, true
			}
		}
	}
	return 0, false
}

func capdTime(raw map[string]any) time.Time {
	for _, key := range []string{"time", "timestamp", "ts"} {
		v, ok := raw[key]
		if !ok {
			continue
		}
		switch x := v.(type) {
		case string:
			if t, err := time.Parse(time.RFC3339Nano, x); err == nil {
				return t
			}
		case float64:
			return time.Unix(int64(x), 0).UTC()
		}
	}
	return time.Time{}
}

func capdStableID(s string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(s))
	return h.Sum64()
}
