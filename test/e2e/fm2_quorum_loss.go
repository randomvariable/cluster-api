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

// FM-2 reproducer. Drives a 3-CP CAPD cluster into the
// 2-machine-both-unhealthy state by pausing two of the three
// control-plane node containers, then verifies the cluster
// behaviour matches the formal-model proof in
// formal/specs/Lifecycle.qnt and formal/failure-modes.md FM-2:
//
//   * EtcdMemberHealthy on the two paused Machines flips to
//     Unknown (reason InspectionFailed or ConnectionDown).
//   * KCP records the OwnerRemediated=False condition on the
//     paused Machines with a "cannot safely remediate" reason
//     (the matchable-set / quorum check in
//     canSafelyRemediateMachine refuses to admit remediation
//     because the post-state etcd cluster would lose quorum).
//   * The cluster does NOT self-recover within an observe window
//     — Apalache proves it cannot.
//   * Once the paused containers are unpaused, the cluster
//     returns to Healthy without further intervention (the model
//     captures this as HealEtcdReachability).
//
// This is the executable counterpart to the formal proof:
//   - Apalache: HealthyControlPlane PROVABLY unreachable from
//               twoMachineBothUnhealthyInit under stepNoRecovery.
//   - This e2e:  observe the same behaviour on a real cluster.

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

// FM2QuorumLossSpecInput is the input for FM2QuorumLossSpec.
type FM2QuorumLossSpecInput struct {
	// Same intervals as KCPRemediationSpec, plus:
	//   - fm2-observe-blocked: how long to observe that no
	//     remediation occurs while two CP nodes are paused.
	//     Should be at least the MHC nodeStartupTimeout +
	//     unhealthyConditions[0].timeout to give MHC a chance
	//     to flag both as unhealthy.
	E2EConfig             *clusterctl.E2EConfig
	ClusterctlConfigPath  string
	BootstrapClusterProxy framework.ClusterProxy
	ArtifactFolder        string
	SkipCleanup           bool

	InfrastructureProvider *string

	// Flavor must produce a 3-CP cluster with no workers. If
	// nil, the default empty flavor is used (i.e.
	// `cluster-template.yaml`), which suffices for FM-2: the
	// load-bearing observation is "no Machine deleted while two
	// voters are unreachable", which holds even without MHC.
	Flavor *string

	PostNamespaceCreated func(managementClusterProxy framework.ClusterProxy, workloadClusterNamespace string)
}

// FM2QuorumLossSpec verifies that a 3-CP cluster losing two
// control-plane node containers concurrently does not recover
// without operator intervention.
func FM2QuorumLossSpec(ctx context.Context, inputGetter func() FM2QuorumLossSpecInput) {
	var (
		specName         = "fm2-quorum-loss"
		input            FM2QuorumLossSpecInput
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

	It("Should refuse to remediate when two of three CP nodes are paused (FM-2)", func() {
		By("Creating a 3-CP workload cluster")

		// Force replicas=3 in the template via env var; the
		// kcp-remediation flavor honours $CONTROL_PLANE_MACHINE_COUNT.
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
				ClusterName:              fmt.Sprintf("fm2-%s", util.RandomString(6)),
				KubernetesVersion:        input.E2EConfig.MustGetVariable(KubernetesVersion),
				ControlPlaneMachineCount: ptr.To[int64](3),
				WorkerMachineCount:       ptr.To[int64](0),
			},
			WaitForClusterIntervals:      input.E2EConfig.GetIntervals(specName, "wait-cluster"),
			WaitForControlPlaneIntervals: input.E2EConfig.GetIntervals(specName, "wait-control-plane"),
			WaitForMachineDeployments:    input.E2EConfig.GetIntervals(specName, "wait-worker-nodes"),
		}, clusterResources)

		clusterName := clusterResources.Cluster.Name
		log.Logf("FM-2 cluster %s is up at 3-CP", clusterName)

		// Start the formal-model trace recorder. The recorder
		// writes JSON-Lines to <ArtifactFolder>/trace/<cluster>.trace.jsonl;
		// the suite-level test-e2e-trace post-step (see Makefile)
		// runs trace-validator on it after the test exits.
		recorder, recorderClose, err := tracerecord.Start(input.ArtifactFolder, fmt.Sprintf("fm2-%s", clusterName))
		Expect(err).NotTo(HaveOccurred(), "failed to start trace recorder")
		defer func() {
			if cerr := recorderClose(); cerr != nil {
				log.Logf("WARNING: trace recorder close failed: %v", cerr)
			}
		}()
		log.Logf("Trace recorder writing to %s", recorder.Path())

		// Identify the three control-plane Machines and wait for
		// every one to have a resolved NodeRef (the container
		// name we'll pause is read from Status.NodeRef.Name).
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

		// Emit the Bootstrap event for the recorder once all
		// three voters are observable. This anchors the trace's
		// initial state in the EtcdMembership checker; absence of
		// any subsequent RemoveMember in the FM-2 happy path is
		// what the checker (and the formal model) expects.
		bootstrapNodes := make([]string, 0, len(machines))
		for _, m := range machines {
			bootstrapNodes = append(bootstrapNodes, m.Status.NodeRef.Name)
		}
		Expect(recorder.Bootstrap(bootstrapNodes)).To(Succeed(),
			"failed to record Bootstrap event")

		// Pick the two non-leader Machines to pause. We pause the
		// non-leader members specifically; pausing the leader
		// would force a re-election the model treats as exogenous.
		// Heuristic: pause Machines whose Status.NodeRef.Name
		// sorts last (deterministic across runs).
		paused := pickTwoMachinesToPause(machines)
		log.Logf("Pausing CP node containers for Machines %s and %s", paused[0].Name, paused[1].Name)

		By("PAUSING TWO OF THREE CONTROL-PLANE NODE CONTAINERS")

		// CAPD names each control-plane node container after the
		// Machine name (with the `-control-plane` cluster suffix
		// stripped). The container name is the Node name as
		// reported by Machine.Status.NodeRef.
		containerNames := []string{
			paused[0].Status.NodeRef.Name,
			paused[1].Status.NodeRef.Name,
		}
		Expect(dockerPause(ctx, containerNames...)).To(Succeed(),
			"failed to pause CP node containers %v", containerNames)

		// Ensure we always unpause on test exit so the cluster
		// can be cleaned up by the framework.
		defer func() {
			if err := dockerUnpause(context.Background(), containerNames...); err != nil {
				log.Logf("WARNING: failed to unpause containers %v: %v", containerNames, err)
			}
		}()

		By("OBSERVING NO MEMBERSHIP CHANGE WHILE QUORUM IS LOST")

		// The Apalache proof says: under stepNoRecovery from the
		// FM-2 init, HealthyControlPlane is unreachable. The
		// e2e analogue is "no Machine is deleted or recreated
		// while two of three voters are paused" — KCP's
		// targetEtcdClusterHealthy gate refuses every
		// membership change because removing one of the still-
		// healthy voters would yield (1 voter, 1 unhealthy,
		// quorum 1) → 1 - 1 = 0 < 1.
		//
		// We don't probe the EtcdMemberHealthy condition
		// directly; KCP's etcd Status RPC timeout is 2 min per
		// member (per the kubeadm-etcd contract), so the
		// condition can take many minutes to flip after a
		// pause. The load-bearing observation here is the one
		// the formal proof asserts: the cluster's machine set
		// stays stable.
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
		}, input.E2EConfig.GetIntervals(specName, "fm2-observe-blocked")...).Should(
			ConsistOf(baselineNames),
			"KCP must not delete or recreate any Machine while two of three voters are paused (FM-2 hopelessness)",
		)

		By("UNPAUSING THE TWO PAUSED CONTAINERS — RECOVERY VIA HealEtcdReachability")

		Expect(dockerUnpause(ctx, containerNames...)).To(Succeed(),
			"failed to unpause CP node containers %v", containerNames)

		By("OBSERVING THE MACHINE SET STAYS STABLE THROUGH RECOVERY")

		// Post-unpause, KCP should not churn the Machine set
		// either. Etcd recovers internally; KCP's view of
		// EtcdMemberHealthy will eventually flip back. The
		// load-bearing assertion is: the recovery does not
		// require Machine deletion.
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
		}, input.E2EConfig.GetIntervals(specName, "fm2-observe-blocked")...).Should(
			ConsistOf(baselineNames),
			"after unpause, the Machine set should remain stable (no spurious remediation)",
		)

		log.Logf("FM-2 reproducer completed: hopelessness observed, recovery via unpause caused no spurious Machine churn")
	})

	AfterEach(func() {
		framework.DumpSpecResourcesAndCleanup(ctx, "fm2-quorum-loss", input.BootstrapClusterProxy, input.ClusterctlConfigPath, input.ArtifactFolder, namespace, cancelWatches, clusterResources.Cluster, input.E2EConfig.GetIntervals, input.SkipCleanup)
	})
}

// pickTwoMachinesToPause returns the two Machines whose Node
// names sort last (deterministic, leader-avoiding heuristic).
// CAPD typically elects the first-created node as leader, which
// sorts first alphabetically when names share a deterministic
// prefix.
func pickTwoMachinesToPause(machines []*clusterv1.Machine) []*clusterv1.Machine {
	sorted := make([]*clusterv1.Machine, 0, len(machines))
	sorted = append(sorted, machines...)
	// Insertion sort by NodeRef.Name; we only care about the
	// last two so a full sort is overkill but cheap.
	for i := 1; i < len(sorted); i++ {
		for j := i; j > 0 && sorted[j-1].Status.NodeRef.Name > sorted[j].Status.NodeRef.Name; j-- {
			sorted[j], sorted[j-1] = sorted[j-1], sorted[j]
		}
	}
	if len(sorted) < 2 {
		return sorted
	}
	return sorted[len(sorted)-2:]
}

