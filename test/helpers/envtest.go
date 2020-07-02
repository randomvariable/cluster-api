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

package helpers

import (
	"io/ioutil"
	"net"
	"path"
	"path/filepath"
	goruntime "runtime"
	"strconv"
	"strings"
	"time"

	"github.com/onsi/ginkgo"

	//. "github.com/onsi/gomega"

	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"

	//admissionv1beta1 "k8s.io/api/admission/v1beta1"
	admissionv1 "k8s.io/api/admissionregistration/v1"
	admissionv1beta1 "k8s.io/api/admissionregistration/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/klog"
	"k8s.io/klog/klogr"
	clusterv1 "sigs.k8s.io/cluster-api/api/v1alpha3"
	bootstrapv1 "sigs.k8s.io/cluster-api/bootstrap/kubeadm/api/v1alpha3"
	"sigs.k8s.io/cluster-api/cmd/clusterctl/log"
	"sigs.k8s.io/cluster-api/controllers/external"
	kcpv1 "sigs.k8s.io/cluster-api/controlplane/kubeadm/api/v1alpha3"
	expv1 "sigs.k8s.io/cluster-api/exp/api/v1alpha3"
	"sigs.k8s.io/cluster-api/util"
	"sigs.k8s.io/cluster-api/util/kubeconfig"
	utilyaml "sigs.k8s.io/cluster-api/util/yaml"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	"sigs.k8s.io/controller-runtime/pkg/manager"
)

func init() {
	klog.InitFlags(nil)
	log.SetLogger(klogr.New())
	klog.SetOutput(ginkgo.GinkgoWriter)
}

var (
	env *envtest.Environment
)

func init() {
	// Calculate the scheme.
	utilruntime.Must(apiextensionsv1.AddToScheme(scheme.Scheme))
	utilruntime.Must(clusterv1.AddToScheme(scheme.Scheme))
	utilruntime.Must(bootstrapv1.AddToScheme(scheme.Scheme))
	utilruntime.Must(expv1.AddToScheme(scheme.Scheme))
	utilruntime.Must(kcpv1.AddToScheme(scheme.Scheme))
	utilruntime.Must(admissionv1beta1.AddToScheme(scheme.Scheme))
	utilruntime.Must(admissionv1.AddToScheme(scheme.Scheme))

	// Get the root of the current file to use in CRD paths.
	_, filename, _, _ := goruntime.Caller(0) //nolint
	root := path.Join(path.Dir(filename), "..", "..")

	// Create the test environment.
	env = &envtest.Environment{
		ErrorIfCRDPathMissing: true,
		CRDDirectoryPaths: []string{
			filepath.Join(root, "config", "crd", "bases"),
			filepath.Join(root, "controlplane", "kubeadm", "config", "crd", "bases"),
			filepath.Join(root, "bootstrap", "kubeadm", "config", "crd", "bases"),
		},
		CRDs: []runtime.Object{
			external.TestGenericBootstrapCRD.DeepCopy(),
			external.TestGenericBootstrapTemplateCRD.DeepCopy(),
			external.TestGenericInfrastructureCRD.DeepCopy(),
			external.TestGenericInfrastructureTemplateCRD.DeepCopy(),
		},
	}

}

// TestEnvironment encapsulates a Kubernetes local test environment.
type TestEnvironment struct {
	manager.Manager
	client.Client
	Config  *rest.Config
	Options manager.Options

	doneMgr chan struct{}
}
type WebhookSupportingType interface {
	SetupWebhookWithManager(ctrl.Manager)
}

// NewTestEnvironment creates a new environment spinning up a local api-server.
//
// This function should be called only once for each package you're running tests within,
// usually the environment is initialized in a suite_test.go file within a `BeforeSuite` ginkgo block.
func NewTestEnvironment() *TestEnvironment {

	// initialize webhook here to be able to test the envtest install via webhookOptions
	initializeWebhookInEnvironment()

	if _, err := env.Start(); err != nil {
		panic(err)
	}

	options := manager.Options{
		Scheme:             scheme.Scheme,
		MetricsBindAddress: "0",
		NewClient:          util.ManagerDelegatingClientFunc,
		CertDir:            env.WebhookInstallOptions.LocalServingCertDir,
		Port:               env.WebhookInstallOptions.LocalServingPort,
	}

	mgr, err := ctrl.NewManager(env.Config, options)

	if err := (&clusterv1.Cluster{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}

	if err := (&clusterv1.Machine{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}

	if err := (&clusterv1.MachineHealthCheck{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}
	if err := (&clusterv1.Machine{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}

	if err := (&clusterv1.MachineSet{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}
	if err := (&clusterv1.MachineDeployment{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}

	if err := (&bootstrapv1.KubeadmConfig{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}

	if err := (&bootstrapv1.KubeadmConfigTemplate{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}

	if err := (&bootstrapv1.KubeadmConfigTemplateList{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}

	if err := (&kcpv1.KubeadmControlPlane{}).SetupWebhookWithManager(mgr); err != nil {
		klog.Fatalf("unable to create webhook: %+v", err)
	}

	if err != nil {
		klog.Fatalf("Failed to start testenv manager: %v", err)
	}

	return &TestEnvironment{
		Manager: mgr,
		Client:  mgr.GetClient(),
		Config:  mgr.GetConfig(),
		doneMgr: make(chan struct{}),
		Options: options,
	}
}

const (
	mutatingWebhookKind   = "MutatingWebhookConfiguration"
	validatingWebhookKind = "ValidatingWebhookConfiguration"
	mutatingwebhook       = "mutating-webhook-configuration"
	validatingwebhook     = "validating-webhook-configuration"
)

func appendWebhookConfiguration(mutatingWebhooks []runtime.Object, validatingWebhooks []runtime.Object, configyamlFile []byte, tag string) ([]runtime.Object, []runtime.Object, error) {

	objs, err := utilyaml.ToUnstructured(configyamlFile)
	if err != nil {
		klog.Fatalf("failed to parse yaml")
	}
	// look for resources of kind MutatingWebhookConfiguration
	for i := range objs {
		o := objs[i]
		if o.GetKind() == mutatingWebhookKind {
			// update the name in metadata
			if o.GetName() == mutatingwebhook {
				o.SetName(strings.Join([]string{mutatingwebhook, "-", tag}, ""))
				mutatingWebhooks = append(mutatingWebhooks, &o)
			}
		}
		if o.GetKind() == validatingWebhookKind {
			// update the name in metadata
			if o.GetName() == validatingwebhook {
				o.SetName(strings.Join([]string{validatingwebhook, "-", tag}, ""))
				validatingWebhooks = append(validatingWebhooks, &o)
			}
		}
	}
	return mutatingWebhooks, validatingWebhooks, err
}

func initializeWebhookInEnvironment() {

	validatingWebhooks := []runtime.Object{}
	mutatingWebhooks := []runtime.Object{}

	// Get the root of the current file to use in CRD paths.
	_, filename, _, _ := goruntime.Caller(0) //nolint
	root := path.Join(path.Dir(filename), "..", "..")
	configyamlFile, err := ioutil.ReadFile(filepath.Join(root, "config", "webhook", "manifests.yaml"))
	if err != nil {
		klog.Fatalf("yamlFile.Get err   #%v ", err)
	}
	if err != nil {
		klog.Fatalf("failed to parse yaml")
	}
	//mutate the name of object if manifest file
	mutatingWebhooks, validatingWebhooks, err = appendWebhookConfiguration(mutatingWebhooks, validatingWebhooks, configyamlFile, "config")
	if err != nil {
		klog.Fatalf(" Failed to append core controller webhook config   #%v ", err)
	}

	bootstrapyamlFile, err := ioutil.ReadFile(filepath.Join(root, "bootstrap", "kubeadm", "config", "webhook", "manifests.yaml"))
	if err != nil {
		klog.Fatalf(" Failed to get bootstrap yaml file err   #%v ", err)
	}
	//mutate the name of object if manifest file
	mutatingWebhooks, validatingWebhooks, err = appendWebhookConfiguration(mutatingWebhooks, validatingWebhooks, bootstrapyamlFile, "bootstrap")

	if err != nil {
		klog.Fatalf(" Failed to append bootstrap controller webhook config   #%v ", err)
	}
	controlplaneyamlFile, err := ioutil.ReadFile(filepath.Join(root, "controlplane", "kubeadm", "config", "webhook", "manifests.yaml"))
	if err != nil {
		klog.Fatalf(" Failed to get controlplane yaml file err   #%v ", err)
	}
	//mutate the name of object if manifest file
	mutatingWebhooks, validatingWebhooks, err = appendWebhookConfiguration(mutatingWebhooks, validatingWebhooks, controlplaneyamlFile, "cp")
	if err != nil {
		klog.Fatalf(" Failed to append cocontrolplane controller webhook config   #%v ", err)
	}
	env.WebhookInstallOptions = envtest.WebhookInstallOptions{
		MaxTime:            20 * time.Second,
		PollInterval:       time.Second,
		ValidatingWebhooks: validatingWebhooks,
		MutatingWebhooks:   mutatingWebhooks,
	}

}
func (t *TestEnvironment) StartManager() error {
	return t.Manager.Start(t.doneMgr)
}

func (t *TestEnvironment) WaitForWebhooks() {
	port := t.Options.Port
	klog.Infof("Waiting for port %d to be open", port)
	timeout := time.Second
	notOpen := true
	for notOpen {
		conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), timeout)
		if err != nil {
			klog.Info("Connecting error", "error", err)
			time.Sleep(time.Second)
		}
		if err == nil && conn != nil {
			klog.Info("Port is open")
			defer conn.Close()
			notOpen = false
		}
	}

}

func (t *TestEnvironment) Stop() error {
	t.doneMgr <- struct{}{}
	return env.Stop()
}

func (t *TestEnvironment) CreateKubeconfigSecret(cluster *clusterv1.Cluster) error {
	return kubeconfig.CreateEnvTestSecret(t.Client, t.Config, cluster)
}
