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
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	clusterv1 "sigs.k8s.io/cluster-api/api/v1alpha3"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal/machinefilters"
	capierrors "sigs.k8s.io/cluster-api/errors"
	"sigs.k8s.io/cluster-api/util"
	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *KubeadmControlPlaneReconciler) initializeControlPlane(ctx context.Context, controlPlane *internal.ControlPlane) (ctrl.Result, error) {
	logger := controlPlane.Logger()

	// Perform an uncached read of all the owned machines. This check is in place to make sure
	// that the controller cache is not misbehaving and we end up initializing the cluster more than once.
	ownedMachines, err := r.managementClusterUncached.GetMachinesForCluster(ctx, util.ObjectKey(controlPlane.Cluster), machinefilters.OwnedMachines(controlPlane.KCP))
	if err != nil {
		logger.Error(err, "failed to perform an uncached read of control plane machines for cluster")
		return ctrl.Result{}, err
	}
	if len(ownedMachines) > 0 {
		return ctrl.Result{}, errors.Errorf(
			"control plane has already been initialized, found %d owned machine for cluster %s/%s: controller cache or management cluster is misbehaving",
			len(ownedMachines), controlPlane.Cluster.Namespace, controlPlane.Cluster.Name,
		)
	}

	bootstrapSpec := controlPlane.InitialControlPlaneConfig()
	fd := controlPlane.FailureDomainWithFewestMachines()
	if err := r.cloneConfigsAndGenerateMachine(ctx, controlPlane, bootstrapSpec, fd); err != nil {
		logger.Error(err, "Failed to create initial control plane Machine")
		r.recorder.Eventf(controlPlane.KCP, corev1.EventTypeWarning, "FailedInitialization", "Failed to create initial control plane Machine for cluster %s/%s control plane: %v", controlPlane.Cluster.Namespace, controlPlane.Cluster.Name, err)
		return ctrl.Result{}, err
	}

	// Requeue the control plane, in case there are additional operations to perform
	return ctrl.Result{Requeue: true}, nil
}

func (r *KubeadmControlPlaneReconciler) scaleUpControlPlane(ctx context.Context, controlPlane *internal.ControlPlane) (ctrl.Result, error) {
	logger := controlPlane.Logger()

	// reconcileHealth returns err if there is a machine being delete which is a required condition to check before scaling up
	if err := r.reconcileHealth(ctx, controlPlane); err != nil {
		return ctrl.Result{}, &capierrors.RequeueAfterError{RequeueAfter: healthCheckFailedRequeueAfter}
	}

	// Create the bootstrap configuration
	bootstrapSpec := controlPlane.JoinControlPlaneConfig()
	fd := controlPlane.FailureDomainWithFewestMachines()
	if err := r.cloneConfigsAndGenerateMachine(ctx, controlPlane, bootstrapSpec, fd); err != nil {
		logger.Error(err, "Failed to create additional control plane Machine")
		r.recorder.Eventf(controlPlane.KCP, corev1.EventTypeWarning, "FailedScaleUp", "Failed to create additional control plane Machine for cluster %s/%s control plane: %v", controlPlane.Cluster.Namespace, controlPlane.Cluster.Name, err)
		return ctrl.Result{}, err
	}

	// Requeue the control plane, in case there are other operations to perform
	return ctrl.Result{Requeue: true}, nil
}

func (r *KubeadmControlPlaneReconciler) scaleDownControlPlane(ctx context.Context, controlPlane *internal.ControlPlane) (ctrl.Result, error) {
	logger := controlPlane.Logger().WithValues("scaling-down", true)

	logger.Info("reconciling health")
	if err := r.reconcileHealth(ctx, controlPlane); err != nil {
		return ctrl.Result{}, &capierrors.RequeueAfterError{RequeueAfter: healthCheckFailedRequeueAfter}
	}

	workloadCluster, err := r.managementCluster.GetWorkloadCluster(ctx, util.ObjectKey(controlPlane.Cluster))
	if err != nil {
		logger.Error(err, "Failed to create client to workload cluster")
		return ctrl.Result{}, errors.Wrapf(err, "failed to create client to workload cluster")
	}

	logger.Info("selecting machine for scale down")
	machineToDelete, err := selectMachineForScaleDown(controlPlane)
	if err != nil {
		return ctrl.Result{}, errors.Wrap(err, "failed to select machine for scale down")
	}

	if machineToDelete == nil {
		logger.Info("Failed to pick control plane Machine to delete")
		return ctrl.Result{}, errors.New("failed to pick control plane Machine to delete")
	}

	logger = logger.WithValues("machine-name", machineToDelete.Name)

	// If etcd leadership is on machine that is about to be deleted, move it to the newest member available.
	logger.Info("ensuring etcd leader is forwarded")
	etcdLeaderCandidate := controlPlane.Machines.Newest()
	if err := workloadCluster.ForwardEtcdLeadership(ctx, machineToDelete, etcdLeaderCandidate); err != nil {
		logger.Error(err, "Failed to move leadership to candidate machine", "candidate", etcdLeaderCandidate.Name)
		return ctrl.Result{}, err
	}
	logger.Info("removing etcd membership")
	if err := workloadCluster.RemoveEtcdMemberForMachine(ctx, machineToDelete); err != nil {
		logger.Error(err, "Failed to remove etcd member for machine")
		return ctrl.Result{}, err
	}

	if err := r.managementCluster.TargetClusterControlPlaneIsHealthy(ctx, util.ObjectKey(controlPlane.Cluster)); err != nil {
		logger.V(2).Info("Waiting for control plane to pass control plane health check before removing a control plane machine", "cause", err)
		r.recorder.Eventf(controlPlane.KCP, corev1.EventTypeWarning, "ControlPlaneUnhealthy",
			"Waiting for control plane to pass control plane health check before removing a control plane machine: %v", err)
		return ctrl.Result{}, &capierrors.RequeueAfterError{RequeueAfter: healthCheckFailedRequeueAfter}

	}
	logger.Info("machines are ready")
	logger.Info("removing machine from kubeadm config map")
	if err := workloadCluster.RemoveMachineFromKubeadmConfigMap(ctx, machineToDelete); err != nil {
		logger.Error(err, "Failed to remove machine from kubeadm ConfigMap")
		return ctrl.Result{}, err
	}

	logger.Info("deleting machine")
	if err := r.Client.Delete(ctx, machineToDelete); err != nil && !apierrors.IsNotFound(err) {
		logger.Error(err, "Failed to delete control plane machine")
		r.recorder.Eventf(controlPlane.KCP, corev1.EventTypeWarning, "FailedScaleDown",
			"Failed to delete control plane Machine %s for cluster %s/%s control plane: %v", machineToDelete.Name, controlPlane.Cluster.Namespace, controlPlane.Cluster.Name, err)
		return ctrl.Result{}, err
	}
	logger.Info("machine deleted")

	// Requeue the control plane, in case there are additional operations to perform
	return ctrl.Result{Requeue: true}, nil
}

func selectMachineForScaleDown(controlPlane *internal.ControlPlane) (*clusterv1.Machine, error) {
	machines := controlPlane.Machines
	if needingUpgrade := controlPlane.MachinesNeedingUpgrade(); needingUpgrade.Len() > 0 {
		machines = needingUpgrade
	}
	return controlPlane.MachineInFailureDomainWithMostMachines(machines)
}
