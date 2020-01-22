package generators

import (
	clusterv1 "sigs.k8s.io/cluster-api/api/v1alpha3"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

func NewMachine(cluster *clusterv1.Cluster) *clusterv1.Machine {
	machine := &clusterv1.Machine{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test",
			Namespace: "test",
			OwnerReferences: []metav1.OwnerReference{
				{
					Kind:       cluster.Kind,
					APIVersion: cluster.GetResourceVersion(),
					Name:       cluster.GetName(),
				},
			},
		},
	}
	return machine
}

func NewControlPlaneMachine(cluster *clusterv1.Cluster) *corev1.List {

	machine := NewMachine(cluster)

	items := []runtime.RawExtension{runtime.RawExtension{Object: machine}}

	list := &corev1.List{
		Items: items,
	}

	return list

}
