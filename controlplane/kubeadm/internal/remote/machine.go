package remote

import (
	"context"

	"k8s.io/apimachinery/pkg/types"
	clusterv1 "sigs.k8s.io/cluster-api/api/v1alpha3"

	"github.com/pkg/errors"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal/etcd"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal/proxy"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type RemoteMachine struct {
	remoteCluster RemoteCluster
	machine       *clusterv1.Machine
}

func NewRemoteMachine(r RemoteCluster, m *clusterv1.Machine) RemoteMachine {
	return RemoteMachine{
		remoteCluster: r,
		machine:       m,
	}
}

func (r RemoteMachine) nodeRef() (*corev1.ObjectReference, error) {
	nodeRef := r.machine.Status.NodeRef
	if nodeRef == nil {
		return nil, errors.New("NodeRef not found")
	}
	return nodeRef, nil
}

func (r RemoteMachine) node() (*corev1.Node, error) {
	nodeRef, err := r.nodeRef()
	if err != nil {
		return nil, err
	}
	node := &corev1.Node{}
	key := types.NamespacedName{
		Namespace: nodeRef.Namespace,
		Name:      nodeRef.Name,
	}
	err = r.remoteCluster.client.Get(context.TODO(), key, node)
	if err != nil {
		return nil, err
	}
	return node, err
}

func (r RemoteMachine) NewEtcdClient() (*etcd.Client, error) {
	restConfig, err := r.remoteCluster.Kubeconfig()
	if err != nil {
		return nil, err
	}
	pod, err := r.GetEtcdPod()
	if err != nil {
		return nil, err
	}
	proxy, err := proxy.NewDialer(proxy.Proxy{
		Kind:         pod.Kind,
		ResourceName: pod.GetName(),
		Namespace:    pod.GetNamespace(),
		KubeConfig:   restConfig,
		Port:         2379,
	})

	if err != nil {
		return nil, err
	}

	TLSConfig, err := r.remoteCluster.newClusterEtcdClientTLSConfig()

	if err != nil {
		return nil, errors.New("blah")
	}

	return etcd.NewClient(proxy.DialContextWithAddr, TLSConfig)
}

func (r RemoteMachine) GetEtcdPod() (*corev1.Pod, error) {

	node, err := r.node()
	if err != nil {
		return nil, err
	}

	l := &corev1.PodList{}
	ctx, cancel := context.WithTimeout(context.Background(), 5)
	err = r.remoteCluster.client.List(
		ctx,
		l,
		client.ListOption(
			client.MatchingLabels{
				"component": "etcd",
				"tier":      "controlplane",
			},
		),
		client.ListOption(
			client.InNamespace(metav1.NamespaceSystem),
		),
	)
	cancel()

	if err != nil {
		return nil, errors.Wrap(err, "unable to list etcd pods")
	}

	for _, p := range l.Items {
		if p.Status.NominatedNodeName == node.GetName() {
			return &p, nil
		}
	}

	return nil, errors.Errorf("no etcd pod found for node: %s", node.GetName())
}
