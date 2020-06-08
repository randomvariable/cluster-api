/*
Copyright 2019 The Kubernetes Authors.

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
	"fmt"
	"time"

	"github.com/blang/semver"
	"github.com/davecgh/go-spew/spew"
	"github.com/go-logr/logr"
	"github.com/pkg/errors"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	kerrors "k8s.io/apimachinery/pkg/util/errors"
	"k8s.io/client-go/tools/record"
	"k8s.io/utils/pointer"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/source"

	clusterv1 "sigs.k8s.io/cluster-api/api/v1alpha3"
	"sigs.k8s.io/cluster-api/bootstrap/kubeadm/api/equality"
	bootstrapv1 "sigs.k8s.io/cluster-api/bootstrap/kubeadm/api/v1alpha3"
	kubeadmv1 "sigs.k8s.io/cluster-api/bootstrap/kubeadm/types/v1beta1"
	controlplanev1 "sigs.k8s.io/cluster-api/controlplane/kubeadm/api/v1alpha3"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal/hash"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal/machinefilters"
	capierrors "sigs.k8s.io/cluster-api/errors"
	"sigs.k8s.io/cluster-api/util"
	"sigs.k8s.io/cluster-api/util/annotations"
	"sigs.k8s.io/cluster-api/util/patch"
	"sigs.k8s.io/cluster-api/util/predicates"
	"sigs.k8s.io/cluster-api/util/secret"
)

// +kubebuilder:rbac:groups=core,resources=events,verbs=get;list;watch;create;patch
// +kubebuilder:rbac:groups=core,resources=secrets,verbs=get;list;watch;create;update;patch
// +kubebuilder:rbac:groups=core,resources=configmaps,namespace=kube-system,verbs=get;list;watch;create
// +kubebuilder:rbac:groups=rbac,resources=roles,namespace=kube-system,verbs=get;list;watch;create
// +kubebuilder:rbac:groups=rbac,resources=rolebindings,namespace=kube-system,verbs=get;list;watch;create
// +kubebuilder:rbac:groups=infrastructure.cluster.x-k8s.io;bootstrap.cluster.x-k8s.io;controlplane.cluster.x-k8s.io,resources=*,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=cluster.x-k8s.io,resources=clusters;clusters/status,verbs=get;list;watch
// +kubebuilder:rbac:groups=cluster.x-k8s.io,resources=machines;machines/status,verbs=get;list;watch;create;update;patch;delete

// KubeadmControlPlaneReconciler reconciles a KubeadmControlPlane object
type KubeadmControlPlaneReconciler struct {
	Client     client.Client
	Log        logr.Logger
	scheme     *runtime.Scheme
	controller controller.Controller
	recorder   record.EventRecorder

	managementCluster         internal.ManagementCluster
	managementClusterUncached internal.ManagementCluster
}

func (r *KubeadmControlPlaneReconciler) SetupWithManager(mgr ctrl.Manager, options controller.Options) error {
	c, err := ctrl.NewControllerManagedBy(mgr).
		For(&controlplanev1.KubeadmControlPlane{}).
		Owns(&clusterv1.Machine{}).
		WithOptions(options).
		WithEventFilter(predicates.ResourceNotPaused(r.Log)).
		Build(r)
	if err != nil {
		return errors.Wrap(err, "failed setting up with a controller manager")
	}

	err = c.Watch(
		&source.Kind{Type: &clusterv1.Cluster{}},
		&handler.EnqueueRequestsFromMapFunc{
			ToRequests: handler.ToRequestsFunc(r.ClusterToKubeadmControlPlane),
		},
		predicates.ClusterUnpausedAndInfrastructureReady(r.Log),
	)
	if err != nil {
		return errors.Wrap(err, "failed adding Watch for Clusters to controller manager")
	}

	r.scheme = mgr.GetScheme()
	r.controller = c
	r.recorder = mgr.GetEventRecorderFor("kubeadm-control-plane-controller")

	if r.managementCluster == nil {
		r.managementCluster = &internal.Management{Client: r.Client}
	}
	if r.managementClusterUncached == nil {
		r.managementClusterUncached = &internal.Management{Client: mgr.GetAPIReader()}
	}

	return nil
}

func (r *KubeadmControlPlaneReconciler) Reconcile(req ctrl.Request) (res ctrl.Result, reterr error) {
	logger := r.Log.WithValues("namespace", req.Namespace, "kubeadmControlPlane", req.Name)
	ctx := context.Background()

	// Fetch the KubeadmControlPlane instance.
	kcp := &controlplanev1.KubeadmControlPlane{}
	if err := r.Client.Get(ctx, req.NamespacedName, kcp); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{Requeue: true}, nil
	}

	// Fetch the Cluster.
	cluster, err := util.GetOwnerCluster(ctx, r.Client, kcp.ObjectMeta)
	if err != nil {
		logger.Error(err, "Failed to retrieve owner Cluster from the API Server")
		return ctrl.Result{}, err
	}
	if cluster == nil {
		logger.Info("Cluster Controller has not yet set OwnerRef")
		return ctrl.Result{}, nil
	}
	logger = logger.WithValues("cluster", cluster.Name)

	if annotations.IsPaused(cluster, kcp) {
		logger.Info("Reconciliation is paused for this object")
		return ctrl.Result{}, nil
	}

	// Wait for the cluster infrastructure to be ready before creating machines
	if !cluster.Status.InfrastructureReady {
		return ctrl.Result{}, nil
	}

	// Initialize the patch helper.
	patchHelper, err := patch.NewHelper(kcp, r.Client)
	if err != nil {
		logger.Error(err, "Failed to configure the patch helper")
		return ctrl.Result{Requeue: true}, nil
	}

	controlPlane := internal.NewControlPlane(cluster, kcp)

	defer func() {
		if requeueErr, ok := errors.Cause(reterr).(capierrors.HasRequeueAfterError); ok {
			if res.RequeueAfter == 0 {
				res.RequeueAfter = requeueErr.GetRequeueAfter()
				reterr = nil
			}
		}

		// Always attempt to update status.
		if err := r.updateStatus(ctx, controlPlane); err != nil {
			var connFailure *internal.RemoteClusterConnectionError
			if errors.As(err, &connFailure) {
				logger.Info("Could not connect to workload cluster to fetch status", "err", err)
			} else {
				logger.Error(err, "Failed to update KubeadmControlPlane Status")
				reterr = kerrors.NewAggregate([]error{reterr, err})
			}
		}

		// Always attempt to Patch the KubeadmControlPlane object and status after each reconciliation.
		if err := patchHelper.Patch(ctx, kcp); err != nil {
			logger.Error(err, "Failed to patch KubeadmControlPlane")
			reterr = kerrors.NewAggregate([]error{reterr, err})
		}

		// TODO: remove this as soon as we have a proper remote cluster cache in place.
		// Make KCP to requeue in case status is not ready, so we can check for node status without waiting for a full resync (by default 10 minutes).
		// Only requeue if we are not going in exponential backoff due to error, or if we are not already re-queueing, or if the object has a deletion timestamp.
		if reterr == nil && !res.Requeue && !(res.RequeueAfter > 0) && kcp.ObjectMeta.DeletionTimestamp.IsZero() {
			if !kcp.Status.Ready {
				res = ctrl.Result{RequeueAfter: 20 * time.Second}
			}
		}
	}()

	if !kcp.ObjectMeta.DeletionTimestamp.IsZero() {
		// Handle deletion reconciliation loop.
		return r.reconcileDelete(ctx, controlPlane)
	}

	// Handle normal reconciliation loop.
	return r.reconcile(ctx, controlPlane)
}

// reconcile handles KubeadmControlPlane reconciliation.
func (r *KubeadmControlPlaneReconciler) reconcile(ctx context.Context, controlPlane *internal.ControlPlane) (res ctrl.Result, reterr error) {
	logger := controlPlane.Logger().WithValues("mode", "normal")
	logger.Info("Reconcile KubeadmControlPlane")

	// If object doesn't have a finalizer, add one.
	controllerutil.AddFinalizer(controlPlane.KCP, controlplanev1.KubeadmControlPlaneFinalizer)

	// Make sure to reconcile the external infrastructure reference.
	if err := r.reconcileExternalReference(ctx, controlPlane.Cluster, controlPlane.KCP.Spec.InfrastructureTemplate); err != nil {
		logger.Error(err, "could not reconcile external reference")
		return ctrl.Result{}, err
	}

	// Generate Cluster Certificates if needed
	config := controlPlane.KCP.Spec.KubeadmConfigSpec.DeepCopy()
	config.JoinConfiguration = nil
	if config.ClusterConfiguration == nil {
		config.ClusterConfiguration = &kubeadmv1.ClusterConfiguration{}
	}
	certificates := secret.NewCertificatesForInitialControlPlane(config.ClusterConfiguration)
	controllerRef := metav1.NewControllerRef(controlPlane.KCP, controlplanev1.GroupVersion.WithKind("KubeadmControlPlane"))
	if err := certificates.LookupOrGenerate(ctx, r.Client, util.ObjectKey(controlPlane.Cluster), *controllerRef); err != nil {
		logger.Error(err, "unable to lookup or create cluster certificates")
		return ctrl.Result{}, err
	}

	// If ControlPlaneEndpoint is not set, return early
	if controlPlane.Cluster.Spec.ControlPlaneEndpoint.IsZero() {
		logger.Info("Cluster does not yet have a ControlPlaneEndpoint defined")
		return ctrl.Result{}, nil
	}

	logger = logger.WithValues("control-plane-endpoint", controlPlane.Cluster.Spec.ControlPlaneEndpoint.String())

	// Generate Cluster Kubeconfig if needed
	if err := r.reconcileKubeconfig(ctx, util.ObjectKey(controlPlane.Cluster), controlPlane.Cluster.Spec.ControlPlaneEndpoint, controlPlane.KCP); err != nil {
		logger.Error(err, "failed to reconcile Kubeconfig")
		return ctrl.Result{}, err
	}

	controlPlaneMachines, err := r.managementCluster.GetMachinesForCluster(ctx, util.ObjectKey(controlPlane.Cluster), machinefilters.ControlPlaneMachines(controlPlane.Cluster.Name))
	if err != nil {
		logger.Error(err, "failed to retrieve control plane machines for cluster")
		return ctrl.Result{}, err
	}

	adoptableMachines := controlPlaneMachines.Filter(machinefilters.AdoptableControlPlaneMachines(controlPlane.Cluster.Name))
	logger.WithValues("adoptable-machines", len(adoptableMachines))
	if len(adoptableMachines) > 0 {
		logger.Info("adopting machines")
		// We adopt the Machines and then wait for the update event for the ownership reference to re-queue them so the cache is up-to-date
		err = r.adoptMachines(ctx, controlPlane, adoptableMachines)
		logger.Error(err, "")
		return ctrl.Result{}, err
	}

	ownedMachines := controlPlaneMachines.Filter(machinefilters.OwnedMachines(controlPlane.KCP))
	if len(ownedMachines) != len(controlPlaneMachines) {
		logger.Info("Not all control plane machines are owned by this KubeadmControlPlane, refusing to operate in mixed management mode")
		return ctrl.Result{}, nil
	}

	controlPlane.Machines = ownedMachines
	requireUpgrade := controlPlane.MachinesNeedingUpgrade()
	// Upgrade takes precedence over other operations
	if len(requireUpgrade) > 0 {
		logger.Info("upgrading")
		return r.upgradeControlPlane(ctx, controlPlane)
	}

	// If we've made it this far, we can assume that all ownedMachines are up to date
	numMachines := len(ownedMachines)
	logger = logger.WithValues("existing-replicas", numMachines)
	desiredReplicas := int(*controlPlane.KCP.Spec.Replicas)
	logger = logger.WithValues("desired-replicas", desiredReplicas)

	switch {
	// We are creating the first replica
	case numMachines < desiredReplicas && numMachines == 0:
		// Create new Machine w/ init
		logger.Info("Initializing control plane")
		return r.initializeControlPlane(ctx, controlPlane)
	// We are scaling up
	case numMachines < desiredReplicas && numMachines > 0:
		// Create a new Machine w/ join
		logger.Info("Scaling up control plane")
		return r.scaleUpControlPlane(ctx, controlPlane)
	// We are scaling down
	case numMachines > desiredReplicas:
		logger.Info("Scaling down control plane")
		return r.scaleDownControlPlane(ctx, controlPlane)
	}

	// Get the workload cluster client.
	workloadCluster, err := r.managementCluster.GetWorkloadCluster(ctx, util.ObjectKey(controlPlane.Cluster))
	if err != nil {
		logger.V(2).Info("cannot get remote client to workload cluster, will requeue", "cause", err)
		return ctrl.Result{Requeue: true}, nil
	}

	// Ensure kubeadm role bindings for v1.18+
	if err := workloadCluster.AllowBootstrapTokensToGetNodes(ctx); err != nil {
		logger.Error(err, "failed to set role and role binding for kubeadm")
		return ctrl.Result{}, errors.Wrap(err, "failed to set role and role binding for kubeadm")
	}

	// Update kube-proxy daemonset.
	if err := workloadCluster.UpdateKubeProxyImageInfo(ctx, controlPlane.KCP); err != nil {
		logger.Error(err, "failed to update kube-proxy daemonset")
		return ctrl.Result{}, err
	}

	// Update CoreDNS deployment.
	if err := workloadCluster.UpdateCoreDNS(ctx, controlPlane.KCP); err != nil {
		logger.Error(err, "failed to update CoreDNS deployment")
		return ctrl.Result{}, errors.Wrap(err, "failed to update CoreDNS deployment")
	}

	logger.Info("Reconcile loop finished")
	return ctrl.Result{}, nil
}

// reconcileDelete handles KubeadmControlPlane deletion.
// The implementation does not take non-control plane workloads into consideration. This may or may not change in the future.
// Please see https://github.com/kubernetes-sigs/cluster-api/issues/2064.
func (r *KubeadmControlPlaneReconciler) reconcileDelete(ctx context.Context, controlPlane *internal.ControlPlane) (_ ctrl.Result, reterr error) {

	logger := controlPlane.Logger().WithValues("mode", "deletion")
	logger.Info("Reconcile KubeadmControlPlane deletion")

	allMachines, err := r.managementCluster.GetMachinesForCluster(ctx, util.ObjectKey(controlPlane.Cluster))
	if err != nil {
		return ctrl.Result{}, err
	}
	logger = logger.WithValues("existing-total-machines", len(allMachines))
	ownedMachines := allMachines.Filter(machinefilters.OwnedMachines(controlPlane.KCP))
	logger = logger.WithValues("existing-replicas", len(ownedMachines))

	// If no control plane machines remain, remove the finalizer
	if len(ownedMachines) == 0 {
		logger.Info("removing finalizer")
		controllerutil.RemoveFinalizer(controlPlane.KCP, controlplanev1.KubeadmControlPlaneFinalizer)
		return ctrl.Result{}, nil
	}

	// Verify that only control plane machines remain
	if len(allMachines) != len(ownedMachines) {
		logger.V(2).Info("Waiting for worker nodes to be deleted first")
		return ctrl.Result{}, &capierrors.RequeueAfterError{RequeueAfter: deleteRequeueAfter}
	}

	// Delete control plane machines in parallel
	machinesToDelete := ownedMachines.Filter(machinefilters.Not(machinefilters.HasDeletionTimestamp))
	var errs []error
	for i := range machinesToDelete {
		m := machinesToDelete[i]
		logger := logger.WithValues("machine-name", m.Name)
		logger.Info("deleting machine")
		if err := r.Client.Delete(ctx, machinesToDelete[i]); err != nil && !apierrors.IsNotFound(err) {
			logger.Error(err, "Failed to cleanup owned machine")
			errs = append(errs, err)
		}
	}
	if len(errs) > 0 {
		err := kerrors.NewAggregate(errs)
		r.recorder.Eventf(controlPlane.KCP, corev1.EventTypeWarning, "FailedDelete",
			"Failed to delete control plane Machines for cluster %s/%s control plane: %v", controlPlane.Cluster.Namespace, controlPlane.Cluster.Name, err)
		return ctrl.Result{}, err
	}
	logger.Info("Reconcile loop finished")
	return ctrl.Result{}, &capierrors.RequeueAfterError{RequeueAfter: deleteRequeueAfter}
}

// ClusterToKubeadmControlPlane is a handler.ToRequestsFunc to be used to enqueue requests for reconciliation
// for KubeadmControlPlane based on updates to a Cluster.
func (r *KubeadmControlPlaneReconciler) ClusterToKubeadmControlPlane(o handler.MapObject) []ctrl.Request {
	c, ok := o.Object.(*clusterv1.Cluster)
	if !ok {
		r.Log.Error(nil, fmt.Sprintf("Expected a Cluster but got a %T", o.Object))
		return nil
	}

	controlPlaneRef := c.Spec.ControlPlaneRef
	if controlPlaneRef != nil && controlPlaneRef.Kind == "KubeadmControlPlane" {
		return []ctrl.Request{{NamespacedName: client.ObjectKey{Namespace: controlPlaneRef.Namespace, Name: controlPlaneRef.Name}}}
	}

	return nil
}

// reconcileHealth performs health checks for control plane components and etcd
// It removes any etcd members that do not have a corresponding node.
// Also, as a final step, checks if there is any machines that is being deleted.
func (r *KubeadmControlPlaneReconciler) reconcileHealth(ctx context.Context, controlPlane *internal.ControlPlane) error {
	logger := controlPlane.Logger()

	// Do a health check of the Control Plane components
	if err := r.managementCluster.TargetClusterControlPlaneIsHealthy(ctx, util.ObjectKey(controlPlane.Cluster)); err != nil {
		logger.V(2).Info("Waiting for control plane to pass control plane health check to continue reconciliation", "cause", err)
		r.recorder.Eventf(controlPlane.KCP, corev1.EventTypeWarning, "ControlPlaneUnhealthy",
			"Waiting for control plane to pass control plane health check to continue reconciliation: %v", err)
		return &capierrors.RequeueAfterError{RequeueAfter: healthCheckFailedRequeueAfter}
	}
	logger.Info("control plane machines ready")

	logger.Info("checking etcd")

	// Ensure etcd is healthy
	if err := r.managementCluster.TargetClusterEtcdIsHealthy(ctx, util.ObjectKey(controlPlane.Cluster)); err != nil {
		// If there are any etcd members that do not have corresponding nodes, remove them from etcd and from the kubeadm configmap.
		// This will solve issues related to manual control-plane machine deletion.
		workloadCluster, err := r.managementCluster.GetWorkloadCluster(ctx, util.ObjectKey(controlPlane.Cluster))
		if err != nil {
			logger.Error(err, "retrieving workload cluster")
			return err
		}
		if err := workloadCluster.ReconcileEtcdMembers(ctx); err != nil {
			logger.V(2).Info("Failed attempt to remove potential hanging etcd members to pass etcd health check to continue reconciliation", "cause", err)
		}

		logger.V(2).Info("Waiting for control plane to pass etcd health check to continue reconciliation", "cause", err)
		r.recorder.Eventf(controlPlane.KCP, corev1.EventTypeWarning, "ControlPlaneUnhealthy",
			"Waiting for control plane to pass etcd health check to continue reconciliation: %v", err)
		return &capierrors.RequeueAfterError{RequeueAfter: healthCheckFailedRequeueAfter}
	}

	logger.Info("etcd healthcheck passed")
	// We need this check for scale up as well as down to avoid scaling up when there is a machine being deleted.
	// This should be at the end of this method as no need to wait for machine to be completely deleted to reconcile etcd.
	// TODO: Revisit during machine remediation implementation which may need to cover other machine phases.
	if controlPlane.HasDeletingMachine() {
		logger.Info("control plane has deletable machines")
		return &capierrors.RequeueAfterError{RequeueAfter: deleteRequeueAfter}
	}

	return nil
}

func (r *KubeadmControlPlaneReconciler) adoptMachines(ctx context.Context, controlPlane *internal.ControlPlane, machines internal.FilterableMachineCollection) error {
	// We do an uncached full quorum read against the KCP to avoid re-adopting Machines the garbage collector just intentionally orphaned
	// See https://github.com/kubernetes/kubernetes/issues/42639
	logger := controlPlane.Logger().WithValues("adoptable-machines", len(machines))
	uncached := controlplanev1.KubeadmControlPlane{}
	err := r.managementClusterUncached.Get(ctx, client.ObjectKey{Namespace: controlPlane.KCP.Namespace, Name: controlPlane.KCP.Name}, &uncached)
	if err != nil {
		logger.Error(err, "failed to check whether controlplane was deleted before adoption")
		return errors.Wrapf(err, "failed to check whether %v/%v was deleted before adoption", controlPlane.KCP.GetNamespace(), controlPlane.KCP.GetName())
	}
	if !uncached.DeletionTimestamp.IsZero() {
		logger.Error(err, "controlplane has just been deleted")
		return errors.Errorf("%v/%v has just been deleted at %v", controlPlane.KCP.GetNamespace(), controlPlane.KCP.GetName(), controlPlane.KCP.GetDeletionTimestamp())
	}

	kcpVersion, err := semver.ParseTolerant(controlPlane.KCP.Spec.Version)
	logger = logger.WithValues("kubernetes-version", controlPlane.KCP.Spec.Version)
	if err != nil {
		logger.Error(err, "failed to parse Kubernetes version")
		return errors.Wrapf(err, "failed to parse kubernetes version %q", controlPlane.KCP.Spec.Version)
	}

	for _, m := range machines {
		ref := m.Spec.Bootstrap.ConfigRef
		mLogger := logger.WithValues("machine-name", m.Name, "machine-version", m.Spec.Version)
		if ref == nil {
			return errors.Errorf("unable to adopt Machine %v/%v: expected a ConfigRef", m.Namespace, m.Name)
		}
		mLogger = mLogger.WithValues("machine-name", m.Name, "config-ref-kind", ref.Kind, "config-ref-name", ref.Name, "config-ref-namespace", ref.Namespace)
		// TODO instead of returning error here, we should instead Event and add a watch on potentially adoptable Machines
		if ref == nil || ref.Kind != "KubeadmConfig" {
			mLogger.Error(err, "unable to adopt machine: expected a ConfigRef of kind KubeadmConfig")
			return errors.Errorf("unable to adopt Machine %v/%v: expected a ConfigRef of kind KubeadmConfig but instead found %v", m.Namespace, m.Name, ref)
		}

		// TODO instead of returning error here, we should instead Event and add a watch on potentially adoptable Machines
		if ref.Namespace != "" && ref.Namespace != controlPlane.KCP.Namespace {
			mLogger.Error(errors.New("cannot adopt resources across namespaces"), "")
			return errors.Errorf("could not adopt resources from KubeadmConfig %v/%v: cannot adopt across namespaces", ref.Namespace, ref.Name)
		}

		if m.Spec.Version == nil {
			// if the machine's version is not immediately apparent, assume the operator knows what they're doing
			logger.Info("nil version, skipping version skew check")
			continue
		}

		machineVersion, err := semver.ParseTolerant(*m.Spec.Version)
		if err != nil {
			mLogger.Error(err, "failed to parse Kubernetes version")
			return errors.Wrapf(err, "failed to parse kubernetes version %q", *m.Spec.Version)
		}

		if !util.IsSupportedVersionSkew(kcpVersion, machineVersion) {
			mLogger.Error(errors.New("cannot adopt machine: version is outside supported +/- one minor version skew from KubeadmControlPlane"), "")
			r.recorder.Eventf(controlPlane.KCP, corev1.EventTypeWarning, "AdoptionFailed", "Could not adopt Machine %s/%s: its version (%q) is outside supported +/- one minor version skew from KCP's (%q)", m.Namespace, m.Name, *m.Spec.Version, controlPlane.KCP.Spec.Version)
			// avoid returning an error here so we don't cause the KCP controller to spin until the operator clarifies their intent
			return nil
		}
	}

	for _, m := range machines {
		ref := m.Spec.Bootstrap.ConfigRef
		cfg := &bootstrapv1.KubeadmConfig{}

		mLogger := logger.WithValues("machine-name", m.Name, m.Namespace, "config-ref-name")
		if err := r.Client.Get(ctx, client.ObjectKey{Name: ref.Name, Namespace: controlPlane.KCP.Namespace}, cfg); err != nil {
			mLogger.Error(err, "")
			return err
		}

		mLogger.Info("adopting owned secrets")
		if err := r.adoptOwnedSecrets(ctx, controlPlane, cfg); err != nil {
			mLogger.Error(err, "")
			return err
		}

		patchHelper, err := patch.NewHelper(m, r.Client)
		if err != nil {
			mLogger.Error(err, "")
			return err
		}

		mLogger.Info("setting controller reference")
		if err := controllerutil.SetControllerReference(controlPlane.KCP, m, r.scheme); err != nil {
			mLogger.Error(err, "")
			return err
		}

		// 0. get machine.Spec.Version - the easy answer
		machineKubernetesVersion := ""
		if m.Spec.Version != nil {
			machineKubernetesVersion = *m.Spec.Version
		}

		mLogger = mLogger.WithValues("machine-kubernetes-version", machineKubernetesVersion)

		// 1. hash the version (kubernetes version) and kubeadm_controlplane's Spec.infrastructureTemplate
		syntheticSpec := controlplanev1.KubeadmControlPlaneSpec{
			Version:                machineKubernetesVersion,
			InfrastructureTemplate: controlPlane.KCP.Spec.InfrastructureTemplate,
			KubeadmConfigSpec:      equality.SemanticMerge(cfg.Spec, controlPlane.KCP.Spec.KubeadmConfigSpec, controlPlane.Cluster),
		}
		newConfigurationHash := hash.Compute(&syntheticSpec)
		mLogger = mLogger.WithValues("synthetic-spec-hash", newConfigurationHash)
		mLogger.Info("computed hash")
		// 2. add kubeadm.controlplane.cluster.x-k8s.io/hash as a label in each machine
		m.Labels[controlplanev1.KubeadmControlPlaneHashLabelKey] = newConfigurationHash

		mLogger.Info("spec dumps", "spec", spew.Sdump(controlPlane.KCP.Spec), "synthetic-spec", spew.Sdump(syntheticSpec))

		// Note that ValidateOwnerReferences() will reject this patch if another
		// OwnerReference exists with controller=true.
		if err := patchHelper.Patch(ctx, m); err != nil {
			mLogger.Error(err, "")
			return err
		}
	}
	return nil
}

func (r *KubeadmControlPlaneReconciler) adoptOwnedSecrets(ctx context.Context, controlPlane *internal.ControlPlane, currentOwner *bootstrapv1.KubeadmConfig) error {
	secrets := corev1.SecretList{}
	logger := controlPlane.Logger().WithValues("kubeadmconfig-owner", currentOwner)
	if err := r.Client.List(ctx, &secrets, client.InNamespace(controlPlane.KCP.Namespace), client.MatchingLabels{clusterv1.ClusterLabelName: controlPlane.Cluster.Name}); err != nil {
		return errors.Wrap(err, "error finding secrets for adoption")
	}

	for i := range secrets.Items {
		s := secrets.Items[i]
		sLogger := logger.WithValues("secret-name", s.Name)
		if !util.IsControlledBy(&s, currentOwner) {
			sLogger.Info("not owned by kubeadmconfig")
			continue
		}
		// avoid taking ownership of the bootstrap data secret
		if currentOwner.Status.DataSecretName != nil && s.Name == *currentOwner.Status.DataSecretName {
			sLogger.Info("not taking ownership of bootstrap data secret", "data-secret-name", currentOwner.Status.DataSecretName)
			continue
		}

		ss := s.DeepCopy()

		sLogger.Info("setting owner references")
		ss.SetOwnerReferences(util.ReplaceOwnerRef(ss.GetOwnerReferences(), currentOwner, metav1.OwnerReference{
			APIVersion:         controlplanev1.GroupVersion.String(),
			Kind:               "KubeadmControlPlane",
			Name:               controlPlane.KCP.Name,
			UID:                controlPlane.KCP.UID,
			Controller:         pointer.BoolPtr(true),
			BlockOwnerDeletion: pointer.BoolPtr(true),
		}))

		if err := r.Client.Update(ctx, ss); err != nil {
			logger.Info("unable to update owner reference")
			return errors.Wrapf(err, "error changing secret %v ownership from KubeadmConfig/%v to KubeadmControlPlane/%v", s.Name, currentOwner.GetName(), controlPlane.KCP.Name)
		}
	}

	return nil
}
