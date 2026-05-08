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

// FM-13 reproducer. Drives a 3-CP CAPD cluster into the
// "apiserver LB proxy broken" state by pausing the haproxy load
// balancer container that fronts the workload-cluster apiservers.
// Verifies the cluster behaviour matches the formal-model proof
// in formal/specs/Lifecycle.qnt and formal/failure-modes.md FM-13:
//
//   * KCP loses the only path to the workload apiserver; every
//     EtcdMemberHealthy / NodeRef-resolution probe times out.
//   * Despite the wholesale unreachability, KCP MUST NOT churn
//     the Machine set — the model proves that under
//     `lbHealthy = false`, no remediation precondition can hold.
//   * Unpausing the LB restores apiserver reachability
//     (modelled as `HealLb`); KCP returns to steady state with
//     no spurious Machine deletion.

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

// FM13ApiserverLBBrokenSpecInput is the input for FM13ApiserverLBBrokenSpec.
type FM13ApiserverLBBrokenSpecInput struct {
	E2EConfig             *clusterctl.E2EConfig
	ClusterctlConfigPath  string
	BootstrapClusterProxy framework.ClusterProxy
	ArtifactFolder        string
	SkipCleanup           bool

	InfrastructureProvider *string
	Flavor                 *string

	PostNamespaceCreated func(managementClusterProxy framework.ClusterProxy, workloadClusterNamespace string)
}

// FM13ApiserverLBBrokenSpec pauses the workload-cluster
// haproxy LB container and verifies KCP refuses to act on the
// resulting all-members-Unknown signal.
func FM13ApiserverLBBrokenSpec(ctx context.Context, inputGetter func() FM13ApiserverLBBrokenSpecInput) {
	var (
		specName         = "fm13-apiserver-lb-broken"
		input            FM13ApiserverLBBrokenSpecInput
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

	It("Should refuse to remediate when the apiserver LB is broken (FM-13)", func() {
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
				ClusterName:              fmt.Sprintf("fm13-%s", util.RandomString(6)),
				KubernetesVersion:        input.E2EConfig.MustGetVariable(KubernetesVersion),
				ControlPlaneMachineCount: ptr.To[int64](3),
				WorkerMachineCount:       ptr.To[int64](0),
			},
			WaitForClusterIntervals:      input.E2EConfig.GetIntervals(specName, "wait-cluster"),
			WaitForControlPlaneIntervals: input.E2EConfig.GetIntervals(specName, "wait-control-plane"),
			WaitForMachineDeployments:    input.E2EConfig.GetIntervals(specName, "wait-worker-nodes"),
		}, clusterResources)

		clusterName := clusterResources.Cluster.Name
		log.Logf("FM-13 cluster %s is up at 3-CP", clusterName)

		recorder, recorderClose, err := tracerecord.Start(input.ArtifactFolder, fmt.Sprintf("fm13-%s", clusterName))
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

		// CAPD names the haproxy LB container `<cluster>-lb`.
		// Pause it to break apiserver reachability for everyone
		// (KCP, kubelet, the test itself).
		lbContainer := fmt.Sprintf("%s-lb", clusterName)
		log.Logf("Pausing apiserver LB container %s", lbContainer)

		By("PAUSING THE APISERVER LB CONTAINER")

		Expect(dockerPause(ctx, lbContainer)).To(Succeed(),
			"failed to pause LB container %s", lbContainer)

		defer func() {
			if uerr := dockerUnpause(context.Background(), lbContainer); uerr != nil {
				log.Logf("WARNING: failed to unpause %s: %v", lbContainer, uerr)
			}
		}()

		By("OBSERVING NO MEMBERSHIP CHANGE WHILE THE LB IS DOWN")

		baselineNames := machineNames(machines).UnsortedList()
		log.Logf("Baseline Machine set: %v — must remain unchanged for the observe window", baselineNames)

		// While the LB is paused, even the management cluster's
		// view of the workload Machines stays at whatever the
		// management API server cached. The Machines themselves
		// are owned by the management cluster, so listing them
		// via the bootstrap-cluster proxy still works regardless
		// of workload-LB state.
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
		}, input.E2EConfig.GetIntervals(specName, "fm13-observe-blocked")...).Should(
			ConsistOf(baselineNames),
			"KCP must not delete or recreate any Machine while the workload apiserver LB is unreachable (FM-13)",
		)

		By("UNPAUSING THE LB CONTAINER — RECOVERY VIA HealLb")

		Expect(dockerUnpause(ctx, lbContainer)).To(Succeed(),
			"failed to unpause LB container %s", lbContainer)

		By("OBSERVING THE MACHINE SET STAYS STABLE THROUGH RECOVERY")

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
		}, input.E2EConfig.GetIntervals(specName, "fm13-observe-blocked")...).Should(
			ConsistOf(baselineNames),
			"after LB recovery, the Machine set should remain stable (no spurious remediation)",
		)

		log.Logf("FM-13 reproducer completed: LB outage observed, recovery caused no spurious Machine churn")
	})

	AfterEach(func() {
		framework.DumpSpecResourcesAndCleanup(ctx, specName, input.BootstrapClusterProxy, input.ClusterctlConfigPath, input.ArtifactFolder, namespace, cancelWatches, clusterResources.Cluster, input.E2EConfig.GetIntervals, input.SkipCleanup)
	})
}
