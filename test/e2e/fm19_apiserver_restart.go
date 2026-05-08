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

// FM-19 reproducer. Drives a 3-CP CAPD cluster into the
// "apiserver restart relist storm" transient by killing the
// kube-apiserver pod on one CP node and observing the cluster's
// behaviour while it restarts. Matches the formal-model proof
// in formal/specs/Lifecycle.qnt and formal/failure-modes.md
// FM-19:
//
//   * The killed apiserver static pod is recreated by the
//     kubelet within a few seconds; during that window MHC may
//     observe the Machine as briefly Unknown, but the model
//     proves no remediation should fire (TRANSIENT).
//   * The Machine set MUST stay stable across the restart.

//go:build e2e

package e2e

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/utils/ptr"

	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	"sigs.k8s.io/cluster-api/test/e2e/internal/log"
	"sigs.k8s.io/cluster-api/test/e2e/internal/tracerecord"
	"sigs.k8s.io/cluster-api/test/framework"
	"sigs.k8s.io/cluster-api/test/framework/clusterctl"
	"sigs.k8s.io/cluster-api/util"
)

// FM19ApiserverRestartSpecInput is the input for FM19ApiserverRestartSpec.
type FM19ApiserverRestartSpecInput struct {
	E2EConfig             *clusterctl.E2EConfig
	ClusterctlConfigPath  string
	BootstrapClusterProxy framework.ClusterProxy
	ArtifactFolder        string
	SkipCleanup           bool

	InfrastructureProvider *string
	Flavor                 *string

	PostNamespaceCreated func(managementClusterProxy framework.ClusterProxy, workloadClusterNamespace string)
}

// FM19ApiserverRestartSpec kills one CP node's kube-apiserver
// static pod and verifies the cluster does not remediate the
// Machine while the pod restarts.
func FM19ApiserverRestartSpec(ctx context.Context, inputGetter func() FM19ApiserverRestartSpecInput) {
	var (
		specName         = "fm19-apiserver-restart"
		input            FM19ApiserverRestartSpecInput
		namespace        *corev1.Namespace
		cancelWatches    context.CancelFunc
		clusterResources *clusterctl.ApplyClusterTemplateAndWaitResult
	)

	BeforeEach(func() {
		Expect(ctx).NotTo(BeNil(), "ctx is required for %s spec", specName)
		input = inputGetter()
		Expect(input.E2EConfig).ToNot(BeNil(), "Invalid argument. input.E2EConfig can't be nil when calling %s spec", specName)
		Expect(input.ClusterctlConfigPath).To(BeAnExistingFile(), "Invalid argument. input.ClusterctlConfigPath must be an existing file when calling %s spec", specName)
		Expect(input.BootstrapClusterProxy).ToNot(BeNil(), "Invalid argument. input.BootstrapClusterProxy can't be nil when calling %s spec", specName)
		Expect(os.MkdirAll(input.ArtifactFolder, 0o750)).To(Succeed(), "Invalid argument. input.ArtifactFolder can't be created for %s spec", specName)
		Expect(input.E2EConfig.Variables).To(HaveKey(KubernetesVersion))

		namespace, cancelWatches = framework.SetupSpecNamespace(ctx, specName, input.BootstrapClusterProxy, input.ArtifactFolder, input.PostNamespaceCreated)
	})

	It("Should not remediate when a CP node's kube-apiserver pod restarts (FM-19)", func() {
		By("Creating a 3-CP workload cluster")

		Expect(os.Setenv("CONTROL_PLANE_MACHINE_COUNT", "3")).To(Succeed())
		Expect(os.Setenv("WORKER_MACHINE_COUNT", "0")).To(Succeed())

		clusterResources = &clusterctl.ApplyClusterTemplateAndWaitResult{}
		clusterctl.ApplyClusterTemplateAndWait(ctx, clusterctl.ApplyClusterTemplateAndWaitInput{
			ClusterProxy: input.BootstrapClusterProxy,
			ConfigCluster: clusterctl.ConfigClusterInput{
				LogFolder:                filepath.Join(input.ArtifactFolder, "clusters", input.BootstrapClusterProxy.GetName()),
				ClusterctlConfigPath:     input.ClusterctlConfigPath,
				KubeconfigPath:           input.BootstrapClusterProxy.GetKubeconfigPath(),
				InfrastructureProvider:   clusterctl.DefaultInfrastructureProvider,
				Flavor:                   ptr.Deref(input.Flavor, ""),
				Namespace:                namespace.Name,
				ClusterName:              fmt.Sprintf("fm19-%s", util.RandomString(6)),
				KubernetesVersion:        input.E2EConfig.MustGetVariable(KubernetesVersion),
				ControlPlaneMachineCount: ptr.To[int64](3),
				WorkerMachineCount:       ptr.To[int64](0),
			},
			WaitForClusterIntervals:      input.E2EConfig.GetIntervals(specName, "wait-cluster"),
			WaitForControlPlaneIntervals: input.E2EConfig.GetIntervals(specName, "wait-control-plane"),
			WaitForMachineDeployments:    input.E2EConfig.GetIntervals(specName, "wait-worker-nodes"),
		}, clusterResources)

		clusterName := clusterResources.Cluster.Name
		log.Logf("FM-19 cluster %s is up at 3-CP", clusterName)

		recorder, recorderClose, err := tracerecord.Start(input.ArtifactFolder, fmt.Sprintf("fm19-%s", clusterName))
		Expect(err).NotTo(HaveOccurred(), "failed to start trace recorder")
		defer func() {
			if cerr := recorderClose(); cerr != nil {
				log.Logf("WARNING: trace recorder close failed: %v", cerr)
			}
		}()
		log.Logf("Trace recorder writing to %s", recorder.Path())

		var machines []*clusterv1.Machine
		Eventually(func() bool {
			ms := framework.GetControlPlaneMachinesByCluster(ctx, framework.GetControlPlaneMachinesByClusterInput{
				Lister:      input.BootstrapClusterProxy.GetClient(),
				ClusterName: clusterName,
				Namespace:   namespace.Name,
			})
			if len(ms) != 3 {
				return false
			}
			machines = make([]*clusterv1.Machine, 0, len(ms))
			for i := range ms {
				if !ms[i].Status.NodeRef.IsDefined() {
					return false
				}
				machines = append(machines, &ms[i])
			}
			return true
		}, input.E2EConfig.GetIntervals(specName, "wait-control-plane")...).Should(BeTrue(),
			"expected 3 control-plane Machines, all with NodeRef resolved")

		bootstrapNodes := make([]string, 0, len(machines))
		for _, m := range machines {
			bootstrapNodes = append(bootstrapNodes, m.Status.NodeRef.Name)
		}
		Expect(recorder.Bootstrap(bootstrapNodes)).To(Succeed(), "failed to record Bootstrap event")

		// Pick a CP container deterministically (lexically last
		// Node name avoids the leader, matching the FM-2/FM-3
		// heuristic).
		victim := pickLastByNodeName(machines)
		container := victim.Status.NodeRef.Name
		log.Logf("Killing kube-apiserver static pod on CP node container %s", container)

		By("KILLING THE APISERVER STATIC POD ON ONE CP NODE")

		// Inside the CAPD CP node, kube-apiserver runs as a
		// static pod; deleting it from the kubelet's view causes
		// the kubelet to relaunch it within a few seconds.
		// `crictl rm -f` is the most reliable verb because the
		// apiserver may be unavailable to talk to itself
		// kubectl-style. The kubelet on the CP node has crictl
		// preinstalled.
		killCmd := []string{
			"sh", "-c",
			"crictl ps -q --label io.kubernetes.container.name=kube-apiserver | xargs -r crictl rm -f",
		}
		_, kerr := dockerExec(ctx, container, killCmd...)
		Expect(kerr).NotTo(HaveOccurred(),
			"failed to kill apiserver pod inside %s", container)

		By("OBSERVING NO MACHINE CHURN WHILE THE APISERVER RESTARTS")

		baselineNames := machineNames(machines).UnsortedList()
		log.Logf("Baseline Machine set: %v — must remain unchanged for the observe window", baselineNames)
		Consistently(func() []string {
			curByValue := framework.GetControlPlaneMachinesByCluster(ctx, framework.GetControlPlaneMachinesByClusterInput{
				Lister:      input.BootstrapClusterProxy.GetClient(),
				ClusterName: clusterName,
				Namespace:   namespace.Name,
			})
			cur := make([]*clusterv1.Machine, 0, len(curByValue))
			for i := range curByValue {
				cur = append(cur, &curByValue[i])
			}
			return machineNames(cur).UnsortedList()
		}, input.E2EConfig.GetIntervals(specName, "fm19-observe-blocked")...).Should(
			ConsistOf(baselineNames),
			"KCP must not delete or recreate any Machine while a single apiserver pod restarts (FM-19 transient)",
		)

		log.Logf("FM-19 reproducer completed: apiserver restart did not trigger spurious remediation")
	})

	AfterEach(func() {
		framework.DumpSpecResourcesAndCleanup(ctx, specName, input.BootstrapClusterProxy, input.ClusterctlConfigPath, input.ArtifactFolder, namespace, cancelWatches, clusterResources.Cluster, input.E2EConfig.GetIntervals, input.SkipCleanup)
	})
}
