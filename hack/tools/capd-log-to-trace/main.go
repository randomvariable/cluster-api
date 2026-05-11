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

package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"sigs.k8s.io/cluster-api/internal/trace"
)

func main() {
	flag.Parse()

	src := "-"
	if len(flag.Args()) >= 1 {
		src = flag.Args()[0]
	}

	rdr, closer, err := openSource(src)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(2)
	}
	if closer != nil {
		defer closer.Close()
	}

	records, err := trace.LoadCAPDLogs(rdr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(2)
	}

	for _, rec := range records {
		line, err := rec.MarshalLine()
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(2)
		}
		if _, err := os.Stdout.Write(line); err != nil {
			fmt.Fprintf(os.Stderr, "error: write output: %v\n", err)
			os.Exit(2)
		}
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
