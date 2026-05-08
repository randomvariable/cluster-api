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

	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers"
)

func main() {
	format := flag.String("format", "jsonl", "trace format: jsonl | itf")
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

	var records []trace.TraceRecord
	switch *format {
	case "jsonl":
		records, err = trace.LoadJSONLines(rdr)
	case "itf":
		records, err = trace.LoadITF(rdr)
	default:
		fmt.Fprintf(os.Stderr, "error: unknown format %q\n", *format)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(2)
	}

	all := []trace.Checker{
		checkers.EtcdMembership{},
		checkers.KubeadmJoin{},
		checkers.KCPReconcile{},
		checkers.MHC{},
	}

	failed := 0
	for _, c := range all {
		v := c.Check(records)
		fmt.Println(v.String())
		if v.IsFailure() {
			failed++
		}
	}

	if failed > 0 {
		fmt.Fprintf(os.Stderr, "\n%d checker(s) reported failures.\n", failed)
		os.Exit(1)
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
