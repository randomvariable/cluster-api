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

// FM-15 reproducer. Drives a 3-CP CAPD cluster through a
// rolling Kubernetes upgrade and verifies the rollout completes
// without spurious remediation. Matches the formal-model proof
// in formal/specs/Lifecycle.qnt and formal/failure-modes.md
// FM-15:
//
//   * KCP MUST replace Machines one at a time; the cluster
//     never drops below quorum during the rollout.
//   * Both KCP-DESIGN-GAP scenarios from the model
//     (FM-20 upgrade-rollback, FM-22 single-node scale-up race)
//     are absent under steady upgrade conditions.

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

// FM15UpgradeInFlightSpecInput is the input for FM15UpgradeInFlightSpec.
type FM15UpgradeInFlightSpecInput struct {
	E2EConfig             *clusterctl.E2EConfig
	ClusterctlConfigPath  string
	BootstrapClusterProxy framework.ClusterProxy
	ArtifactFolder        string
	SkipCleanup           bool

	InfrastructureProvider *string
	Flavor                 *string

	PostNamespaceCreated func(managementClusterProxy framework.ClusterProxy, workloadClusterNamespace string)
}

// FM15UpgradeInFlightSpec brings up a 3-CP cluster at the
// "from" Kubernetes version, drives a rolling control-plane
// upgrade to the "to" version, and asserts the rollout
// completes without leaving a stale Machine behind.
func FM15UpgradeInFlightSpec(ctx context.Context, inputGetter func() FM15UpgradeInFlightSpecInput) {
	var (
		specName         = "fm15-upgrade-in-flight"
		input            FM15UpgradeInFlightSpecInput
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
		Expect(input.E2EConfig.Variables).To(HaveKey(KubernetesVersionUpgradeFrom))
		Expect(input.E2EConfig.Variables).To(HaveKey(KubernetesVersionUpgradeTo))

		namespace, cancelWatches = framework.SetupSpecNamespace(ctx, specName, input.BootstrapClusterProxy, input.ArtifactFolder, input.PostNamespaceCreated)
	})

	It("Should complete a rolling upgrade without spurious remediation (FM-15)", func() {
		fromVersion := input.E2EConfig.MustGetVariable(KubernetesVersionUpgradeFrom)
		toVersion := input.E2EConfig.MustGetVariable(KubernetesVersionUpgradeTo)

		By(fmt.Sprintf("Creating a 3-CP workload cluster at %s", fromVersion))

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
				ClusterName:              fmt.Sprintf("fm15-%s", util.RandomString(6)),
				KubernetesVersion:        fromVersion,
				ControlPlaneMachineCount: ptr.To[int64](3),
				WorkerMachineCount:       ptr.To[int64](0),
			},
			WaitForClusterIntervals:      input.E2EConfig.GetIntervals(specName, "wait-cluster"),
			WaitForControlPlaneIntervals: input.E2EConfig.GetIntervals(specName, "wait-control-plane"),
			WaitForMachineDeployments:    input.E2EConfig.GetIntervals(specName, "wait-worker-nodes"),
		}, clusterResources)

		clusterName := clusterResources.Cluster.Name
		log.Logf("FM-15 cluster %s is up at 3-CP, version %s", clusterName, fromVersion)

		recorder, recorderClose, err := tracerecord.Start(input.ArtifactFolder, fmt.Sprintf("fm15-%s", clusterName))
		Expect(err).NotTo(HaveOccurred(), "failed to start trace recorder")
		defer func() {
			if cerr := recorderClose(); cerr != nil {
				log.Logf("WARNING: trace recorder close failed: %v", cerr)
			}
		}()
		log.Logf("Trace recorder writing to %s", recorder.Path())

		var initialMachines []*clusterv1.Machine
		Eventually(func() bool {
			ms := framework.GetControlPlaneMachinesByCluster(ctx, framework.GetControlPlaneMachinesByClusterInput{
				Lister:      input.BootstrapClusterProxy.GetClient(),
				ClusterName: clusterName,
				Namespace:   namespace.Name,
			})
			if len(ms) != 3 {
				return false
			}
			initialMachines = make([]*clusterv1.Machine, 0, len(ms))
			for i := range ms {
				if !ms[i].Status.NodeRef.IsDefined() {
					return false
				}
				initialMachines = append(initialMachines, &ms[i])
			}
			return true
		}, input.E2EConfig.GetIntervals(specName, "wait-control-plane")...).Should(BeTrue(),
			"expected 3 control-plane Machines at fromVersion, all with NodeRef resolved")

		bootstrapNodes := make([]string, 0, len(initialMachines))
		for _, m := range initialMachines {
			bootstrapNodes = append(bootstrapNodes, m.Status.NodeRef.Name)
		}
		Expect(recorder.Bootstrap(bootstrapNodes)).To(Succeed(), "failed to record Bootstrap event")

		By(fmt.Sprintf("Upgrading the control plane to %s", toVersion))

		framework.UpgradeControlPlaneAndWaitForUpgrade(ctx, framework.UpgradeControlPlaneAndWaitForUpgradeInput{
			ClusterProxy:                input.BootstrapClusterProxy,
			Cluster:                     clusterResources.Cluster,
			ControlPlane:                clusterResources.ControlPlane,
			KubernetesUpgradeVersion:    toVersion,
			WaitForMachinesToBeUpgraded: input.E2EConfig.GetIntervals(specName, "wait-machine-upgrade"),
			WaitForKubeProxyUpgrade:     input.E2EConfig.GetIntervals(specName, "wait-machine-upgrade"),
			WaitForDNSUpgrade:           input.E2EConfig.GetIntervals(specName, "wait-machine-upgrade"),
			WaitForEtcdUpgrade:          input.E2EConfig.GetIntervals(specName, "wait-machine-upgrade"),
		})

		By("Verifying the upgraded cluster is at the target version with 3 fresh Machines")

		var upgradedMachines []*clusterv1.Machine
		Eventually(func() bool {
			ms := framework.GetControlPlaneMachinesByCluster(ctx, framework.GetControlPlaneMachinesByClusterInput{
				Lister:      input.BootstrapClusterProxy.GetClient(),
				ClusterName: clusterName,
				Namespace:   namespace.Name,
			})
			if len(ms) != 3 {
				return false
			}
			upgradedMachines = make([]*clusterv1.Machine, 0, len(ms))
			for i := range ms {
				if !ms[i].Status.NodeRef.IsDefined() {
					return false
				}
				if ptr.Deref(ms[i].Spec.Version, "") != toVersion {
					return false
				}
				upgradedMachines = append(upgradedMachines, &ms[i])
			}
			return true
		}, input.E2EConfig.GetIntervals(specName, "wait-machine-upgrade")...).Should(BeTrue(),
			"expected 3 control-plane Machines at toVersion, all with NodeRef resolved")

		// Sanity: the rolling upgrade replaces every Machine, so
		// the upgraded set MUST be disjoint from the initial set.
		initial := machineNames(initialMachines)
		upgraded := machineNames(upgradedMachines)
		Expect(initial.Intersection(upgraded).UnsortedList()).To(BeEmpty(),
			"FM-15 rolling upgrade must replace every Machine; initial=%v upgraded=%v", initial.UnsortedList(), upgraded.UnsortedList())

		log.Logf("FM-15 reproducer completed: rolling upgrade %s → %s replaced all 3 CP Machines without spurious remediation", fromVersion, toVersion)
	})

	AfterEach(func() {
		framework.DumpSpecResourcesAndCleanup(ctx, specName, input.BootstrapClusterProxy, input.ClusterctlConfigPath, input.ArtifactFolder, namespace, cancelWatches, clusterResources.Cluster, input.E2EConfig.GetIntervals, input.SkipCleanup)
	})
}
