//go:build tools
// +build tools

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

// trace-validator runs every checker in
// sigs.k8s.io/cluster-api/internal/trace/checkers against a
// JSON-Lines or Quint ITF trace file (or stdin) and prints one
// verdict per checker. It exits non-zero if any checker reported
// a failure.
//
// Usage:
//
//	trace-validator [-format jsonl|itf] [trace-file|-]
//
// trace-file defaults to "-" (stdin). Format defaults to jsonl.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers"
)

func main() {
	format := flag.String("format", "jsonl", "trace format: jsonl | itf | capdlog")
	differential := flag.Bool("differential", false, "classify checker failures as real-trace discrepancies")
	defaultClassification := flag.String("default-classification", "controller-bug", "classification for checker failures in differential mode: controller-bug | spec-bug | translator-gap")
	discrepancyLog := flag.String("discrepancy-log", "", "optional file to append discrepancy summaries to in differential mode")
	flag.Parse()

	args := flag.Args()
	src := "-"
	if len(args) >= 1 {
		src = args[0]
	}

	rdr, closer, err := openSource(src)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(2)
	}
	if closer != nil {
		defer closer.Close()
	}

	records, err := loadRecords(*format, rdr)
	if err != nil {
		if *differential {
			fmt.Printf("DISCREPANCY [translator-gap] load failure — %v\n", err)
			maybeAppendDiscrepancy(*discrepancyLog, "translator-gap", *format, trace.Verdict{Reason: err.Error()})
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(2)
	}

	verdicts, failed := evaluate(records)
	for _, v := range verdicts {
		fmt.Println(v.String())
		if *differential && v.IsFailure() {
			classification := classify(v, *defaultClassification)
			fmt.Printf("DISCREPANCY [%s] %s\n", classification, v.String())
			maybeAppendDiscrepancy(*discrepancyLog, classification, *format, v)
		}
	}

	if failed > 0 {
		fmt.Fprintf(os.Stderr, "\n%d checker(s) reported failures.\n", failed)
		os.Exit(1)
	}
}

func loadRecords(format string, rdr io.Reader) ([]trace.TraceRecord, error) {
	switch format {
	case "jsonl":
		return trace.LoadJSONLines(rdr)
	case "itf":
		return trace.LoadITF(rdr)
	case "capdlog":
		return trace.LoadCAPDLogs(rdr)
	default:
		return nil, fmt.Errorf("unknown format %q", format)
	}
}

func evaluate(records []trace.TraceRecord) ([]trace.Verdict, int) {
	all := []trace.Checker{
		checkers.EtcdMembership{},
		checkers.KubeadmJoin{},
		checkers.KCPReconcile{},
		checkers.MHC{},
	}

	verdicts := make([]trace.Verdict, 0, len(all))
	failed := 0
	for _, c := range all {
		v := c.Check(records)
		verdicts = append(verdicts, v)
		if v.IsFailure() {
			failed++
		}
	}
	return verdicts, failed
}

func classify(v trace.Verdict, fallback string) string {
	if v.Invariant == "MalformedRecord" {
		return "translator-gap"
	}
	if fallback == "spec-bug" || fallback == "translator-gap" || fallback == "controller-bug" {
		return fallback
	}
	return "controller-bug"
}

func maybeAppendDiscrepancy(path, classification, format string, v trace.Verdict) {
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: append discrepancy log: %v\n", err)
		return
	}
	defer f.Close()
	line := fmt.Sprintf("| pending | %s | %s | %s | %s | %s |\n",
		classification,
		format,
		v.Spec,
		strings.TrimSpace(v.Invariant),
		strings.TrimSpace(v.Reason),
	)
	if _, err := f.WriteString(line); err != nil {
		fmt.Fprintf(os.Stderr, "warning: write discrepancy log: %v\n", err)
	}
}

func openSource(src string) (io.Reader, io.Closer, error) {
	if src == "-" {
		return os.Stdin, nil, nil
	}
	f, err := os.Open(src)
	if err != nil {
		return nil, nil, fmt.Errorf("open %s: %w", src, err)
	}
	return f, f, nil
}
