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
	"os"
	"testing"
)

func TestLoadRecordsCAPDLogFixture(t *testing.T) {
	t.Parallel()

	f, err := os.Open("../../../internal/trace/testdata/capd_kcp_mhc.jsonl")
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()

	records, err := loadRecords("capdlog", f)
	if err != nil {
		t.Fatalf("loadRecords(capdlog): %v", err)
	}
	if len(records) == 0 {
		t.Fatal("expected translated records")
	}

	verdicts, failed := evaluate(records)
	if failed != 0 {
		t.Fatalf("expected no checker failures, got %d: %+v", failed, verdicts)
	}
}

func TestLoadRecordsCAPDLogTranslatorGapFixture(t *testing.T) {
	t.Parallel()

	f, err := os.Open("../../../internal/trace/testdata/capd_translator_gap_missing_node.jsonl")
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()

	_, err = loadRecords("capdlog", f)
	if err == nil {
		t.Fatal("expected translator gap fixture to fail loading")
	}
}
