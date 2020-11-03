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

package kubernetesversions

import (
	"errors"
	"io/ioutil"
	"os"
	"os/exec"
	"path"

	cabpkv1 "sigs.k8s.io/cluster-api/bootstrap/kubeadm/api/v1alpha4"
	kcpv1 "sigs.k8s.io/cluster-api/controlplane/kubeadm/api/v1alpha4"
	"sigs.k8s.io/cluster-api/test/framework"
	"sigs.k8s.io/yaml"
)

type jsonPatchOperation string

const (
	jsonPatchOperationAdd                jsonPatchOperation = "add"
	jsonPatchOperationReplace            jsonPatchOperation = "replace"
	yamlSeparator                                           = "\n---\n"
	renderedConformanceTemplateName                         = "cluster-template-conformance-ci-artifacts.yaml"
	renderedKubeadmConfigPatchName                          = "kubeadmConfig-patch.yaml"
	renderedKubeadmControlPlanePatchName                    = "kubeadmControlPlane-patch.yaml"
	sourceTemplateName                                      = "ci-artifacts-source-template.yaml"
	platformSMPName                                         = "platform-kustomization.yaml"
	kustomizationFileName                                   = "kustomization.yaml"
)

type simplifiedPatchOp struct {
	Operation jsonPatchOperation `json:"op"`
	Path      string             `json:"path"`
	Value     interface{}        `json:"value"`
}

type kustomizeTarget struct {
	Group   string `json:"group"`
	Version string `json:"version"`
	Kind    string `json:"kind"`
	Name    string `json:"name"`
}

type patchJSON6902 struct {
	Target kustomizeTarget `json:"target"`
	Path   string          `json:"path"`
}

type simplifiedKustomization struct {
	APIVersion            string          `json:"apiVersion"`
	Kind                  string          `json:"kind"`
	Namespace             string          `json:"namespace"`
	Resources             []string        `json:"resources"`
	PatchesStrategicMerge []string        `json:"patchesStrategicMerge,omitempty"`
	PatchesJSON6902       []patchJSON6902 `json:"patchesJson6902,omitempty"`
}

type GenerateCIArtifactsInjectedTemplateForDebianInput struct {
	// ArtifactsDirectory is where conformance suite output will go. Defaults to _artifacts
	ArtifactsDirectory string
	// SourceTemplate is an input YAML clusterctl template which is to have
	// the CI artifact script injection
	SourceTemplate []byte
	// PlatformKustomization is an SMP (strategic-merge-style) patch for adding
	// platform specific kustomizations required for use with CI, such as
	// referencing a specific image
	PlatformKustomization []byte
	// KubeadmConfigTemplateName is the name of the KubeadmConfigTemplate resource
	// that needs to have the Debian install script injected. Defaults to "${CLUSTER_NAME}-md-0".
	KubeadmConfigTemplateName string
	// KubeadmControlPlaneName is the name of the KubeadmControlPlane resource
	// that needs to have the Debian install script injected. Defaults to "${CLUSTER_NAME}-control-plane".
	KubeadmControlPlaneName string
	// KubeadmConfigName is the name of a KubeadmConfig that needs kustomizing. To be used in conjunction with MachinePools. Optional.
	KubeadmConfigName string
}

// GenerateCIArtifactsInjectedTemplateForDebian takes a source clusterctl template
// and a platform-specific Kustomize SMP patch and injects a bash script to download
// and install the debian packages for the given Kubernetes version, returning the
// location of the outputted file.
func GenerateCIArtifactsInjectedTemplateForDebian(input GenerateCIArtifactsInjectedTemplateForDebianInput) (string, error) {
	if input.SourceTemplate == nil {
		return "", errors.New("SourceTemplate must be provided")
	}
	input.ArtifactsDirectory = framework.ResolveArtifactsDirectory(input.ArtifactsDirectory)
	if input.KubeadmConfigTemplateName == "" {
		input.KubeadmConfigTemplateName = "${CLUSTER_NAME}-md-0"
	}
	if input.KubeadmControlPlaneName == "" {
		input.KubeadmControlPlaneName = "${CLUSTER_NAME}-control-plane"
	}
	templateDir := path.Join(input.ArtifactsDirectory, "templates")
	overlayDir := path.Join(input.ArtifactsDirectory, "overlay")

	if err := os.MkdirAll(templateDir, 0o750); err != nil {
		return "", err
	}
	if err := os.MkdirAll(overlayDir, 0o750); err != nil {
		return "", err
	}

	kustomizedTemplate := path.Join(templateDir, renderedConformanceTemplateName)

	kubeadmConfigPatch, err := kubeadmConfigInjectionPatch()
	if err != nil {
		return "", err
	}
	if err := ioutil.WriteFile(path.Join(overlayDir, renderedKubeadmConfigPatchName), kubeadmConfigPatch, 0o600); err != nil {
		return "", err
	}

	kubeadmControlPlanePatch, err := kubeadmControlPlaneInjectionPatch()
	if err != nil {
		return "", err
	}
	if err := ioutil.WriteFile(path.Join(overlayDir, renderedKubeadmControlPlanePatchName), kubeadmControlPlanePatch, 0o600); err != nil {
		return "", err
	}

	if err := ioutil.WriteFile(path.Join(overlayDir, sourceTemplateName), input.SourceTemplate, 0o600); err != nil {
		return "", err
	}

	if err := ioutil.WriteFile(path.Join(overlayDir, platformSMPName), input.PlatformKustomization, 0o600); err != nil {
		return "", err
	}

	kustomization := newSimplifiedKustomization()
	kustomization.Resources = []string{sourceTemplateName}
	kustomization.PatchesStrategicMerge = []string{platformSMPName}
	kustomization.PatchesJSON6902 = []patchJSON6902{
		{
			Target: kustomizeTarget{
				Group:   cabpkv1.GroupVersion.Group,
				Version: cabpkv1.GroupVersion.Version,
				Kind:    "KubeadmConfigTemplate",
				Name:    input.KubeadmConfigTemplateName,
			},
			Path: renderedKubeadmConfigPatchName,
		},
		{
			Target: kustomizeTarget{
				Group:   kcpv1.GroupVersion.Group,
				Version: kcpv1.GroupVersion.Version,
				Kind:    "KubeadmControlPlane",
				Name:    input.KubeadmControlPlaneName,
			},
			Path: renderedKubeadmControlPlanePatchName,
		},
	}

	if input.KubeadmConfigName != "" {
		kustomization.PatchesJSON6902 = append(
			kustomization.PatchesJSON6902,
			patchJSON6902{
				Target: kustomizeTarget{
					Group:   cabpkv1.GroupVersion.Group,
					Version: cabpkv1.GroupVersion.Version,
					Kind:    "KubeadmConfig",
					Name:    input.KubeadmConfigName,
				},
				Path: renderedKubeadmConfigPatchName,
			},
		)
	}

	kustomizationYaml, err := yaml.Marshal(kustomization)
	if err != nil {
		return "", err
	}

	ioutil.WriteFile(path.Join(overlayDir, kustomizationFileName), kustomizationYaml, 0o600)

	cmd := exec.Command("kustomize", "build", overlayDir)
	data, err := cmd.CombinedOutput()
	if err != nil {
		return "", err
	}
	if err := ioutil.WriteFile(kustomizedTemplate, data, 0o600); err != nil {
		return "", err
	}
	return kustomizedTemplate, nil

}

func newSimplifiedKustomization() simplifiedKustomization {
	return simplifiedKustomization{
		APIVersion: "kustomize.config.k8s.io/v1beta1",
		Kind:       "Kustomization",
		Namespace:  "default",
	}
}

func kubeadmConfigInjectionPatch() ([]byte, error) {
	data, err := dataDebian_injection_scriptEnvsubstShBytes()
	if err != nil {
		return nil, err
	}
	file := cabpkv1.File{
		Path:        "/usr/local/bin/ci-artifacts.sh",
		Content:     string(data),
		Owner:       "root:root",
		Permissions: "0750",
	}

	patches := []simplifiedPatchOp{
		{
			Operation: jsonPatchOperationAdd,
			Path:      "/spec/files",
			Value:     file,
		},
		{
			Operation: jsonPatchOperationAdd,
			Path:      "/spec/preKubeadmCommands",
			Value:     "/usr/local/bin/ci-artifacts.sh",
		},
	}

	return yaml.Marshal(patches)

}

func kubeadmControlPlaneInjectionPatch() ([]byte, error) {
	data, err := dataDebian_injection_scriptEnvsubstShBytes()
	if err != nil {
		return nil, err
	}
	file := cabpkv1.File{
		Path:        "/usr/local/bin/ci-artifacts.sh",
		Content:     string(data),
		Owner:       "root:root",
		Permissions: "0750",
	}

	patches := []simplifiedPatchOp{
		{
			Operation: jsonPatchOperationAdd,
			Path:      "/spec/kubeadmConfigSpec/files",
			Value:     file,
		},
		{
			Operation: jsonPatchOperationAdd,
			Path:      "/spec/kubeadmConfigSpec/preKubeadmCommands",
			Value:     "/usr/local/bin/ci-artifacts.sh",
		},
		{
			Operation: jsonPatchOperationReplace,
			Path:      "/spec/version",
			Value:     "${KUBERNETES_VERSION}",
		},
	}

	return yaml.Marshal(patches)
}
