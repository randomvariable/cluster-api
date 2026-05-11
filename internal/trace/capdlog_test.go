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

package trace_test

import (
	"os"
	"strings"
	"testing"

	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers"
)

func TestLoadCAPDLogs_Fixtures(t *testing.T) {
	t.Parallel()

	fixtures := []string{
		"testdata/capd_etcd_membership.jsonl",
		"testdata/capd_kubeadm_join.jsonl",
		"testdata/capd_kcp_mhc.jsonl",
	}

	all := []trace.Checker{
		checkers.EtcdMembership{},
		checkers.KubeadmJoin{},
		checkers.KCPReconcile{},
		checkers.MHC{},
	}

	for _, fixture := range fixtures {
		fixture := fixture
		t.Run(fixture, func(t *testing.T) {
			t.Parallel()

			f, err := os.Open(fixture)
			if err != nil {
				t.Fatalf("open fixture: %v", err)
			}
			defer f.Close()

			records, err := trace.LoadCAPDLogs(f)
			if err != nil {
				t.Fatalf("LoadCAPDLogs: %v", err)
			}
			if len(records) == 0 {
				t.Fatal("expected translated records")
			}

			for _, c := range all {
				v := c.Check(records)
				if v.IsFailure() {
					t.Fatalf("checker %s reported failure: %s", c.Spec(), v)
				}
			}
		})
	}
}

func TestLoadCAPDLogs_RecognisedMessageRequiresFields(t *testing.T) {
	t.Parallel()

	_, err := trace.LoadCAPDLogs(strings.NewReader("{\"msg\":\"Adding etcd member\"}\n"))
	if err == nil {
		t.Fatal("expected translator error for recognised message without node field")
	}
}
