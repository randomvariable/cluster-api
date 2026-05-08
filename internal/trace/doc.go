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

// Package trace implements the runtime side of the formal model
// in formal/specs/. Every Quint or TLA+ action declared in the
// formal/abstraction-mapping.md table has a refining Go entry
// point; when those entry points emit TraceRecord events, the
// per-spec Checkers in this package's checkers/ subpackage
// consume the resulting trace and verify the model's invariants.
//
// The package is deliberately decoupled from controller-runtime
// at the API level. Recorder is a thin wrapper that any
// controller can call without importing additional dependencies;
// the trace can be written to JSON Lines for off-line validation
// by the hack/tools/trace-validator CLI, or consumed in-process
// by a long-running checker for development feedback.
//
// See formal/README.md for the methodology and
// docs/proposals/20260507-formal-control-plane-lifecycle-model.md
// for the rationale.
package trace
