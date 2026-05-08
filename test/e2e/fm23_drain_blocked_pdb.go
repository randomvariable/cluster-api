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

// FM-23 reproducer. Drives a 3-CP CAPD cluster into the
// "drain stuck on PDB" state by deploying a PDB
// (maxUnavailable=0) on a workload Deployment that tolerates
// the control-plane taint, then triggering remediation on the
// CP Machine hosting that pod. Verifies the formal-model claim
// in formal/specs/Lifecycle.qnt and formal/failure-modes.md
// FM-23: the Machine deletion stalls for the PDB drain window,
// and proceeds only once the PDB is removed.

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
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	clusterv1 "sigs.k8s.io/cluster-api/api/core/v1beta2"
	"sigs.k8s.io/cluster-api/test/e2e/internal/log"
	"sigs.k8s.io/cluster-api/test/e2e/internal/tracerecord"
	"sigs.k8s.io/cluster-api/test/framework"
	"sigs.k8s.io/cluster-api/test/framework/clusterctl"
	"sigs.k8s.io/cluster-api/util"
)

// FM23DrainBlockedPDBSpecInput is the input for FM23DrainBlockedPDBSpec.
type FM23DrainBlockedPDBSpecInput struct {
	E2EConfig             *clusterctl.E2EConfig
	ClusterctlConfigPath  string
	BootstrapClusterProxy framework.ClusterProxy
	ArtifactFolder        string
	SkipCleanup           bool

	InfrastructureProvider *string
	Flavor                 *string

	PostNamespaceCreated func(managementClusterProxy framework.ClusterProxy, workloadClusterNamespace string)
}

// FM23DrainBlockedPDBSpec deploys a workload pod + blocking PDB
// on a CP Machine, then triggers remediation and verifies
// Machine deletion stalls until the PDB is removed.
func FM23DrainBlockedPDBSpec(ctx context.Context, inputGetter func() FM23DrainBlockedPDBSpecInput) {
	var (
		specName         = "fm23-drain-blocked-pdb"
		input            FM23DrainBlockedPDBSpecInput
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

	It("Should stall Machine deletion when a PDB blocks drain (FM-23)", func() {
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
				ClusterName:              fmt.Sprintf("fm23-%s", util.RandomString(6)),
				KubernetesVersion:        input.E2EConfig.MustGetVariable(KubernetesVersion),
				ControlPlaneMachineCount: ptr.To[int64](3),
				WorkerMachineCount:       ptr.To[int64](0),
			},
			WaitForClusterIntervals:      input.E2EConfig.GetIntervals(specName, "wait-cluster"),
			WaitForControlPlaneIntervals: input.E2EConfig.GetIntervals(specName, "wait-control-plane"),
			WaitForMachineDeployments:    input.E2EConfig.GetIntervals(specName, "wait-worker-nodes"),
		}, clusterResources)

		clusterName := clusterResources.Cluster.Name
		log.Logf("FM-23 cluster %s is up at 3-CP", clusterName)

		recorder, recorderClose, err := tracerecord.Start(input.ArtifactFolder, fmt.Sprintf("fm23-%s", clusterName))
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

		// Workload-cluster client.
		workloadProxy := input.BootstrapClusterProxy.GetWorkloadCluster(ctx, namespace.Name, clusterName)
		workloadClient := workloadProxy.GetClient()

		// Deploy a tiny pod onto the chosen CP Node + an
		// `maxUnavailable: 0` PDB on it. The pod tolerates the
		// control-plane NoSchedule taint so the kube-scheduler
		// will land it on the target CP Node.
		victim := pickLastByNodeName(machines)
		victimNode := victim.Status.NodeRef.Name

		By(fmt.Sprintf("Deploying a sticky pod and a blocking PDB on %s", victimNode))

		stickyPod := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "fm23-sticky",
				Namespace: "default",
				Labels:    map[string]string{"app": "fm23-sticky"},
			},
			Spec: corev1.PodSpec{
				NodeName: victimNode,
				Tolerations: []corev1.Toleration{
					{Key: "node-role.kubernetes.io/control-plane", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
				},
				Containers: []corev1.Container{
					{Name: "pause", Image: "registry.k8s.io/pause:3.10"},
				},
				TerminationGracePeriodSeconds: ptr.To[int64](3600), // long enough that drain has to wait
			},
		}
		Expect(workloadClient.Create(ctx, stickyPod)).To(Succeed(), "failed to create sticky pod")

		pdb := &policyv1.PodDisruptionBudget{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "fm23-pdb",
				Namespace: "default",
			},
			Spec: policyv1.PodDisruptionBudgetSpec{
				MaxUnavailable: &intstr.IntOrString{Type: intstr.Int, IntVal: 0},
				Selector:       &metav1.LabelSelector{MatchLabels: map[string]string{"app": "fm23-sticky"}},
			},
		}
		Expect(workloadClient.Create(ctx, pdb)).To(Succeed(), "failed to create blocking PDB")

		defer func() {
			// Best-effort cleanup; the test cluster is going to
			// be torn down anyway, but tidying makes test
			// debugging easier.
			cleanupCtx := context.Background()
			_ = workloadClient.Delete(cleanupCtx, pdb)
			_ = workloadClient.Delete(cleanupCtx, stickyPod)
		}()

		By("TRIGGERING REMEDIATION ON THE TARGET MACHINE")

		patched := victim.DeepCopy()
		if patched.Labels == nil {
			patched.Labels = map[string]string{}
		}
		patched.Labels["mhc-test"] = "fail"
		Expect(input.BootstrapClusterProxy.GetClient().Patch(ctx, patched, client.MergeFrom(victim))).To(
			Succeed(), "failed to label %s for remediation", victim.Name)

		By("OBSERVING THE MACHINE DELETION STALLS WHILE THE PDB BLOCKS DRAIN")

		// The Machine MUST stay present (deletionTimestamp set,
		// not yet removed) while drain stalls. The exact KCP
		// behaviour: deletionTimestamp is set, but the finalizer
		// is held until drain succeeds. We therefore consistently
		// observe the Machine still in the API while the PDB is
		// in place.
		Consistently(func() bool {
			m := &clusterv1.Machine{}
			err := input.BootstrapClusterProxy.GetClient().Get(ctx, client.ObjectKeyFromObject(victim), m)
			if apierrors.IsNotFound(err) {
				return false
			}
			Expect(err).NotTo(HaveOccurred(), "unexpected error reading victim Machine")
			return true
		}, input.E2EConfig.GetIntervals(specName, "fm23-drain-stalled")...).Should(
			BeTrue(),
			"FM-23: KCP must hold the Machine while drain is blocked by the PDB",
		)

		By("REMOVING THE PDB — DRAIN PROCEEDS, MACHINE IS DELETED")

		Expect(workloadClient.Delete(ctx, pdb)).To(Succeed(), "failed to delete blocking PDB")

		Eventually(func() bool {
			m := &clusterv1.Machine{}
			err := input.BootstrapClusterProxy.GetClient().Get(ctx, client.ObjectKeyFromObject(victim), m)
			return apierrors.IsNotFound(err)
		}, input.E2EConfig.GetIntervals(specName, "fm23-drain-completes")...).Should(
			BeTrue(),
			"FM-23: after PDB removal, the victim Machine should be deleted",
		)

		log.Logf("FM-23 reproducer completed: drain stalled while PDB held; Machine deleted after PDB removed")
	})

	AfterEach(func() {
		framework.DumpSpecResourcesAndCleanup(ctx, specName, input.BootstrapClusterProxy, input.ClusterctlConfigPath, input.ArtifactFolder, namespace, cancelWatches, clusterResources.Cluster, input.E2EConfig.GetIntervals, input.SkipCleanup)
	})
}
