/*
Copyright 2020 The Kubernetes Authors.

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

package controllers

import (
	"context"

	"github.com/pkg/errors"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal/hash"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal/machinefilters"
	"sigs.k8s.io/cluster-api/util"
)

// updateStatus is called after every reconcilitation loop in a defer statement to always make sure we have the
// resource status subresourcs up-to-date.
func (r *KubeadmControlPlaneReconciler) updateStatus(ctx context.Context, controlPlane *internal.ControlPlane) error {
	selector := machinefilters.ControlPlaneSelectorForCluster(controlPlane.Cluster.Name)
	// Copy label selector to its status counterpart in string format.
	// This is necessary for CRDs including scale subresources.
	controlPlane.KCP.Status.Selector = selector.String()

	ownedMachines, err := r.managementCluster.GetMachinesForCluster(ctx, util.ObjectKey(controlPlane.Cluster), machinefilters.OwnedMachines(controlPlane.KCP))
	if err != nil {
		return errors.Wrap(err, "failed to get list of owned machines")
	}

	currentMachines := ownedMachines.Filter(machinefilters.MatchesConfigurationHash(hash.Compute(&controlPlane.KCP.Spec)))
	controlPlane.KCP.Status.UpdatedReplicas = int32(len(currentMachines))

	replicas := int32(len(ownedMachines))

	// set basic data that does not require interacting with the workload cluster
	controlPlane.KCP.Status.Replicas = replicas
	controlPlane.KCP.Status.ReadyReplicas = 0
	controlPlane.KCP.Status.UnavailableReplicas = replicas

	// Return early if the deletion timestamp is set, we don't want to try to connect to the workload cluster.
	if !controlPlane.KCP.DeletionTimestamp.IsZero() {
		return nil
	}

	workloadCluster, err := r.managementCluster.GetWorkloadCluster(ctx, util.ObjectKey(controlPlane.Cluster))
	if err != nil {
		return errors.Wrap(err, "failed to create remote cluster client")
	}
	status, err := workloadCluster.ClusterStatus(ctx)
	if err != nil {
		return err
	}
	controlPlane.KCP.Status.ReadyReplicas = status.ReadyNodes
	controlPlane.KCP.Status.UnavailableReplicas = replicas - status.ReadyNodes

	// This only gets initialized once and does not change if the kubeadm config map goes away.
	if status.HasKubeadmConfig {
		controlPlane.KCP.Status.Initialized = true
	}

	if controlPlane.KCP.Status.ReadyReplicas > 0 {
		controlPlane.KCP.Status.Ready = true
	}

	return nil
}
