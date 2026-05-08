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
	"io"
	"strconv"
)

// LoadJSONLines reads a JSON-Lines trace from `r` and returns the
// parsed records. Lines that fail to parse are returned as an
// error pointing at the offending line number; the caller MAY
// inspect partial output via the returned slice.
func LoadJSONLines(r io.Reader) ([]TraceRecord, error) {
	out := make([]TraceRecord, 0, 256)
	sc := bufio.NewScanner(r)
	// Allow long lines — modelled traces can carry verbose Vars.
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		rec, err := UnmarshalLine(line)
		if err != nil {
			return out, fmt.Errorf("line %d: %w", lineNo, err)
		}
		out = append(out, *rec)
	}
	if err := sc.Err(); err != nil {
		return out, fmt.Errorf("scan: %w", err)
	}
	return out, nil
}

// LoadITF parses a Quint-emitted Informal Trace Format (ITF) JSON
// document and converts it to a slice of TraceRecord. The ITF
// document follows ADR-015 (apalache-mc.org/docs/adr/015adr-trace).
//
// Quint emits ITF under three modes:
//
//   1. `quint run --out-itf=...`  — vanilla; states carry only
//      variable values, no action name.
//   2. `quint run --mbt --out-itf=...`  — model-based-testing
//      mode; each state carries two extra synthetic variables:
//        * `mbt::actionTaken`  — the action name as a string
//        * `mbt::nondetPicks`  — the non-deterministically chosen
//          parameters of the action, as a map of {paramName ->
//          Option<value>}.
//      This is the mode the trace-replay sweep uses (issue #11)
//      because the action name + picks together reconstruct the
//      transition that the per-spec checkers ingest.
//   3. Apalache `--write-itf-to-file` — same shape as (1) but
//      with `#meta.action` set on each state.
//
// LoadITF detects which shape is present and populates the
// Action / Vars fields accordingly:
//
//   - If `#meta.action` is set on a state, use it.
//   - Else if `mbt::actionTaken` is set, use that and populate
//     Vars from the unwrapped `mbt::nondetPicks` map.
//   - Else leave Action empty (the trace can still be useful for
//     state-only invariants but the checkers will treat
//     unrecognised records as Inapplicable).
//
// The trace's Spec field is inferred from the action name via
// InferSpecFromAction. Spec inference may return an empty
// SpecModule if the action name is unknown to the dispatcher; in
// that case the offline trace-validator CLI applies every
// checker, and each one returns Inapplicable.
func LoadITF(r io.Reader) ([]TraceRecord, error) {
	type itfMeta struct {
		Action string         `json:"action,omitempty"`
		Args   map[string]any `json:"args,omitempty"`
		Index  *int           `json:"index,omitempty"`
	}
	// State variables in the real ITF format are TOP-LEVEL keys,
	// alongside the `#meta` field. Decode the whole state into
	// a generic map and then peel off the meta separately.
	type itfDoc struct {
		Vars   []string         `json:"vars"`
		States []map[string]any `json:"states"`
	}
	var doc itfDoc
	if err := json.NewDecoder(r).Decode(&doc); err != nil {
		return nil, fmt.Errorf("decode itf: %w", err)
	}
	out := make([]TraceRecord, 0, len(doc.States))
	for i, raw := range doc.States {
		rec := TraceRecord{
			Seq:  uint64(i + 1),
			Vars: map[string]any{},
		}

		// Apalache-style explicit action on `#meta`.
		if metaRaw, ok := raw["#meta"]; ok {
			if metaMap, ok := metaRaw.(map[string]any); ok {
				if act, ok := metaMap["action"].(string); ok && act != "" {
					rec.Action = Action(act)
				}
				if args, ok := metaMap["args"].(map[string]any); ok {
					for k, v := range args {
						rec.Vars[k] = unwrapITFValue(v)
					}
				}
			}
		}

		// Quint MBT-mode action + non-deterministic picks.
		if rec.Action == "" {
			if act, ok := raw["mbt::actionTaken"].(string); ok && act != "" {
				rec.Action = Action(act)
			}
		}
		if picksRaw, ok := raw["mbt::nondetPicks"]; ok {
			if picks := unwrapITFValue(picksRaw); picks != nil {
				if pmap, ok := picks.(map[string]any); ok {
					for k, v := range pmap {
						// Picks are wrapped as `Option<T>`; only
						// surface defined picks. None values stay
						// out of Vars so checkers can use the
						// `present` flag of the AsXxx helpers.
						if v == nil {
							continue
						}
						rec.Vars[k] = v
					}
				}
			}
		}

		// Copy the remaining state variables so per-record
		// invariant checks have access to the post-state when
		// they need it.
		for k, v := range raw {
			if k == "#meta" || k == "mbt::actionTaken" || k == "mbt::nondetPicks" {
				continue
			}
			if _, alreadyPresent := rec.Vars[k]; alreadyPresent {
				continue
			}
			rec.Vars[k] = unwrapITFValue(v)
		}

		rec.Spec = InferSpecFromAction(rec.Action)
		applyParamAliases(&rec)
		out = append(out, rec)
	}
	return out, nil
}

// unwrapITFValue strips the ITF wrapper objects (`#bigint`,
// `#set`, `#map`, `#tup`) and Quint's algebraic-datatype
// `{tag, value}` envelopes, returning a plain Go value the
// checker helpers can consume via type assertion.
//
//   {"#bigint":"42"}                       -> int64(42)
//   {"#set":[a, b, c]}                     -> []any{a, b, c}
//   {"#map":[[k, v], ...]}                 -> map[string]any{...}
//   {"#tup":[]}                            -> nil
//   {"tag":"Some","value":x}               -> unwrap(x)
//   {"tag":"None","value":...}             -> nil
//   {"tag":"Foo","value":x}                -> "Foo:" + repr(x)  (sum-type tag preserved as string)
func unwrapITFValue(v any) any {
	switch x := v.(type) {
	case map[string]any:
		if s, ok := x["#bigint"].(string); ok {
			n, err := strconv.ParseInt(s, 10, 64)
			if err == nil {
				return n
			}
			return s
		}
		if s, ok := x["#set"].([]any); ok {
			out := make([]any, 0, len(s))
			for _, e := range s {
				out = append(out, unwrapITFValue(e))
			}
			return out
		}
		if m, ok := x["#map"].([]any); ok {
			out := map[string]any{}
			for _, pair := range m {
				p, ok := pair.([]any)
				if !ok || len(p) != 2 {
					continue
				}
				k := unwrapITFValue(p[0])
				val := unwrapITFValue(p[1])
				out[fmt.Sprintf("%v", k)] = val
			}
			return out
		}
		if _, ok := x["#tup"]; ok {
			return nil
		}
		if tag, hasTag := x["tag"].(string); hasTag {
			val, hasVal := x["value"]
			switch tag {
			case "Some":
				if hasVal {
					return unwrapITFValue(val)
				}
				return nil
			case "None":
				return nil
			default:
				// Preserve the sum-type tag for downstream
				// consumers that care (e.g. progress labels like
				// "Eligible", "Stuck"). Just the tag string.
				return tag
			}
		}
		out := map[string]any{}
		for k, val := range x {
			out[k] = unwrapITFValue(val)
		}
		return out
	case []any:
		out := make([]any, 0, len(x))
		for _, e := range x {
			out = append(out, unwrapITFValue(e))
		}
		return out
	default:
		return v
	}
}

// actionParamAliases maps a Quint action's parameter names (as
// emitted by `--mbt`'s `mbt::nondetPicks`) onto the canonical
// names the Go checkers in internal/trace/checkers/ expect. The
// mismatch arises because the spec authors named parameters
// concisely (`m`, `id`, `c`) while the checkers were written
// against a recorder vocabulary (`machine`, `id`, `candidate`).
//
// Aliases are applied DESTRUCTIVELY in LoadITF: the source key
// is dropped and the target key is set. If the source is absent,
// the alias is a no-op.
var actionParamAliases = map[Action]map[string]string{
	// EtcdMembership.qnt
	"AddLearner":             {"id": "id"},
	"PromoteLearner":         {"id": "id"},
	"RemoveMember":           {"id": "id"},
	"ObserveLearnerProgress": {"id": "id", "p": "progress"},
	"LearnerStuck":           {"id": "id"},
	"ElectLeader":            {"c": "candidate", "currentTerm": "term"},
	"MemberHealthChange":     {"id": "id", "h": "health"},
	// KubeadmJoin.qnt
	"BeginJoin":               {"m": "machine"},
	"PreflightPass":           {"m": "machine"},
	"PreflightFail":           {"m": "machine"},
	"KubeletStarted":          {"m": "machine"},
	"RegisterLocalNode":       {"m": "machine"},
	"EtcdAddLearnerSucceeded": {"m": "machine"},
	"EtcdAddLearnerFailed":    {"m": "machine"},
	"WaitForEtcdQuorum":       {"m": "machine"},
	"MarkControlPlaneReady":   {"m": "machine"},
	"JoinComplete":            {"m": "machine"},
	"JoinFailed":              {"m": "machine"},
	// KCPReconcile.qnt
	"AddMachine":                 {"m": "machine"},
	"DeleteFailedMachine":        {"m": "machine"},
	"ResolveNodeRef":             {"m": "machine"},
	"RequestRemediation":         {"m": "machine"},
	"CompleteRemediation":        {"m": "machine"},
	"EvaluateCanSafelyRemediate": {"m": "machine"},
	"ScaleUpControlPlane":        {"m": "machine"},
	"ScaleDownControlPlane":      {"m": "machine"},
	"InitiateUpgrade":            {"t": "template"},
	"MarkReady":                  {"m": "machine"},
	// MachineHealthCheck.qnt
	"MachineHealthChange": {"m": "machine", "h": "health"},
	"DeriveCondition":     {"m": "machine"},
}

// applyParamAliases rewrites a record's Vars keys according to
// the spec's parameter-name aliases for the record's Action.
func applyParamAliases(rec *TraceRecord) {
	aliases, ok := actionParamAliases[rec.Action]
	if !ok {
		return
	}
	for src, dst := range aliases {
		if src == dst {
			continue
		}
		if v, present := rec.Vars[src]; present {
			rec.Vars[dst] = v
			delete(rec.Vars, src)
		}
	}
}

// InferSpecFromAction maps a Quint action name to the SpecModule
// whose checker is responsible for it. The mapping mirrors the
// per-spec action vocabulary in formal/abstraction-mapping.md.
// Unknown actions return an empty SpecModule; the offline
// validator runs every checker against such records and each
// one returns Inapplicable.
func InferSpecFromAction(action Action) SpecModule {
	switch action {
	case "Bootstrap", "AddLearner", "PromoteLearner", "RemoveMember",
		"ObserveLearnerProgress", "LearnerStuck", "ElectLeader",
		"AdvanceTerm", "MemberHealthChange":
		return SpecEtcdMembership
	case "BeginJoin", "PreflightPass", "PreflightFail",
		"KubeletStarted", "RegisterLocalNode",
		"EtcdAddLearnerSucceeded", "EtcdAddLearnerFailed",
		"WaitForEtcdQuorum", "MarkControlPlaneReady",
		"JoinComplete", "JoinFailed":
		return SpecKubeadmJoin
	case "EvaluateCanSafelyRemediate", "RequestRemediation",
		"CompleteRemediation", "ScaleUpControlPlane",
		"ScaleDownControlPlane", "InitiateUpgrade",
		"AddMachine", "DeleteFailedMachine", "MarkReady",
		"ResolveNodeRef":
		return SpecKCPReconcile
	case "MachineHealthChange", "DeriveCondition", "MhcCacheStale",
		"MhcCacheRefresh":
		return SpecMachineHealthCheck
	}
	return ""
}
