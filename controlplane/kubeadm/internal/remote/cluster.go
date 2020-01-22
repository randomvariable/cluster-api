package remote

import (
	"context"
	"crypto/tls"
	"crypto/x509"

	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
	clusterv1 "sigs.k8s.io/cluster-api/api/v1alpha3"
	"sigs.k8s.io/cluster-api/controllers/remote"
	"sigs.k8s.io/cluster-api/util/secret"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/cluster-api/controlplane/kubeadm/internal/proxy"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type RemoteCluster struct {
	client  client.Client
	cluster *clusterv1.Cluster
}

func NewRemoteCluster(client client.Client, cluster *clusterv1.Cluster) RemoteCluster {
	return RemoteCluster{
		client:  client,
		cluster: cluster,
	}
}

// EtcdClientTlsConfig
func (r RemoteCluster) newClusterEtcdClientTLSConfig() (*tls.Config, error) {
	certificates := secret.NewCertificatesForEtcdClient()
	certificates.Lookup(context.TODO(), r.client, types.NamespacedName{
		Namespace: r.cluster.GetNamespace(),
		Name:      r.cluster.GetClusterName(),
	})
	clientCert := certificates.GetByPurpose(secret.APIServerEtcdClient)
	caCert := certificates.GetByPurpose(secret.EtcdCA)
	clientKeyPair, _ := tls.X509KeyPair(clientCert.KeyPair.Cert, clientCert.KeyPair.Key)

	caPool := x509.NewCertPool()
	caPool.AppendCertsFromPEM(caCert.KeyPair.Cert)

	return &tls.Config{
		RootCAs:      caPool,
		Certificates: []tls.Certificate{clientKeyPair},
	}, nil
}

func (r RemoteCluster) Kubeconfig() (*rest.Config, error) {
	return remote.RESTConfig(r.client, r.cluster)
}

func (r RemoteCluster) etcdPodDialer(p *corev1.Pod) (*proxy.Dialer, error) {
	restConfig, err := r.Kubeconfig()
	if err != nil {
		return nil, err
	}
	return proxy.NewDialer(proxy.Proxy{
		Kind:         p.Kind,
		ResourceName: p.GetName(),
		Namespace:    p.GetNamespace(),
		KubeConfig:   restConfig,
		Port:         2379,
	})
}
