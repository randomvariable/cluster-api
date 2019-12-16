# -*- mode: Bazel -*-

settings = {
    "core": {
        "default_image": "gcr.io/k8s-staging-cluster-api/cluster-api-controller",
    },
    "provider": "docker",
}

# global settings
settings.update(read_json(
    "config.json",
    default = {},
))

allow_k8s_contexts(settings.get("k8s_contexts"))

default_registry(settings.get("default_registry"))

image = settings.get("core")["default_image"]

# Install cert-manager if not installed
local("make install-cert-manager-into-context")

provider = settings.get("provider")

# Gather manifests
capi_manifests = kustomize("config/default")

# Install manifests
k8s_yaml(capi_manifests)

# Build processes
docker_build(
    image,
    ".",
    dockerfile = "development.Dockerfile",
    ignore = ["test/*"],
    live_update = [
        sync("cmd", "/workspace/cmd"),
        sync("api", "/workspace/api"),
        sync("errors", "/workspace/errors"),
        sync("util", "/workspace/util"),
        sync("bootstrap", "/workspace/bootstrap"),
        sync("controllers", "/workspace/controllers"),
        sync("third_party/kubernetes-drain", "/workspace/third_party/kubernetes-drain"),
        sync("main.go", "/workspace/main.go"),
        run("go build -o /manager ."),
        run("./restart.sh"),
    ],
    target = "builder",
)

if provider == "docker":
  include("test/infrastructure/docker/Tiltfile")
else:
  include("providers/" + provider + "Tiltfile")
