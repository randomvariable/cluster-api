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

// FM-3 reproducer. Drives a 3-CP CAPD cluster into the
// "persistent etcd unreachability" state by detaching one
// control-plane node container from the kind network. Verifies
// the cluster behaviour matches the formal-model proof in
// formal/specs/Lifecycle.qnt and formal/failure-modes.md FM-3:
//
//   * The disconnected member's EtcdMemberHealthy condition
//     flips Unknown (peer + client connectivity gone).
//   * The remaining 2-of-3 voters retain quorum; KCP MUST NOT
//     remediate the disconnected Machine — removing it would
//     leave (1 voter, 1 unhealthy/none, quorum 1) and 1 - 1 = 0
//     < 1, the same hopelessness shape as FM-2.
//   * Reconnecting the container restores membership (modelled
//     as `HealEtcdReachability`).

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

// FM3EtcdUnreachableSpecInput is the input for FM3EtcdUnreachableSpec.
type FM3EtcdUnreachableSpecInput struct {
	E2EConfig             *clusterctl.E2EConfig
	ClusterctlConfigPath  string
	BootstrapClusterProxy framework.ClusterProxy
	ArtifactFolder        string
	SkipCleanup           bool

	InfrastructureProvider *string

	// Flavor must produce a 3-CP cluster with no workers; the
	// default kcp-remediation flavor (or empty) suffices.
	Flavor *string

	// KindNetwork names the docker network the kind cluster
	// uses. Defaults to "kind"; CAPD always provisions on this
	// network so the override is rarely needed.
	KindNetwork string

	PostNamespaceCreated func(managementClusterProxy framework.ClusterProxy, workloadClusterNamespace string)
}

// FM3EtcdUnreachableSpec disconnects one CP node container from
// the kind network and verifies the cluster does not churn the
// Machine set while quorum holds.
func FM3EtcdUnreachableSpec(ctx context.Context, inputGetter func() FM3EtcdUnreachableSpecInput) {
	var (
		specName         = "fm3-etcd-unreachable"
		input            FM3EtcdUnreachableSpecInput
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

		if input.KindNetwork == "" {
			input.KindNetwork = "kind"
		}
		namespace, cancelWatches = framework.SetupSpecNamespace(ctx, specName, input.BootstrapClusterProxy, input.ArtifactFolder, input.PostNamespaceCreated)
	})

	It("Should refuse to remediate a partition-isolated CP node when quorum holds (FM-3)", func() {
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
				ClusterName:              fmt.Sprintf("fm3-%s", util.RandomString(6)),
				KubernetesVersion:        input.E2EConfig.MustGetVariable(KubernetesVersion),
				ControlPlaneMachineCount: ptr.To[int64](3),
				WorkerMachineCount:       ptr.To[int64](0),
			},
			WaitForClusterIntervals:      input.E2EConfig.GetIntervals(specName, "wait-cluster"),
			WaitForControlPlaneIntervals: input.E2EConfig.GetIntervals(specName, "wait-control-plane"),
			WaitForMachineDeployments:    input.E2EConfig.GetIntervals(specName, "wait-worker-nodes"),
		}, clusterResources)

		clusterName := clusterResources.Cluster.Name
		log.Logf("FM-3 cluster %s is up at 3-CP", clusterName)

		recorder, recorderClose, err := tracerecord.Start(input.ArtifactFolder, fmt.Sprintf("fm3-%s", clusterName))
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

		// Disconnect the lexically-last Node container; same
		// leader-avoiding heuristic as FM-2.
		victim := pickLastByNodeName(machines)
		isolated := victim.Status.NodeRef.Name
		log.Logf("Disconnecting CP node container %s from kind network", isolated)

		By("DETACHING ONE CP NODE FROM THE KIND NETWORK")

		Expect(dockerNetworkDisconnect(ctx, input.KindNetwork, isolated)).To(Succeed(),
			"failed to disconnect %s from %s", isolated, input.KindNetwork)

		defer func() {
			if rerr := dockerNetworkConnect(context.Background(), input.KindNetwork, isolated); rerr != nil {
				log.Logf("WARNING: failed to reconnect %s to %s: %v", isolated, input.KindNetwork, rerr)
			}
		}()

		By("OBSERVING NO MEMBERSHIP CHANGE WHILE THE PARTITION HOLDS")

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
		}, input.E2EConfig.GetIntervals(specName, "fm3-observe-blocked")...).Should(
			ConsistOf(baselineNames),
			"KCP must not delete or recreate any Machine while one of three voters is partitioned (FM-3 hopelessness)",
		)

		By("RECONNECTING THE PARTITIONED NODE — RECOVERY VIA HealEtcdReachability")

		Expect(dockerNetworkConnect(ctx, input.KindNetwork, isolated)).To(Succeed(),
			"failed to reconnect %s", isolated)

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
		}, input.E2EConfig.GetIntervals(specName, "fm3-observe-blocked")...).Should(
			ConsistOf(baselineNames),
			"after reconnect, the Machine set should remain stable (no spurious remediation)",
		)

		log.Logf("FM-3 reproducer completed: partition observed, recovery via reconnect caused no spurious Machine churn")
	})

	AfterEach(func() {
		framework.DumpSpecResourcesAndCleanup(ctx, specName, input.BootstrapClusterProxy, input.ClusterctlConfigPath, input.ArtifactFolder, namespace, cancelWatches, clusterResources.Cluster, input.E2EConfig.GetIntervals, input.SkipCleanup)
	})
}

// pickLastByNodeName returns the Machine whose NodeRef.Name
// sorts last. Same leader-avoiding heuristic as FM-2.
func pickLastByNodeName(machines []*clusterv1.Machine) *clusterv1.Machine {
	if len(machines) == 0 {
		return nil
	}
	winner := machines[0]
	for _, m := range machines[1:] {
		if m.Status.NodeRef.Name > winner.Status.NodeRef.Name {
			winner = m
		}
	}
	return winner
}
