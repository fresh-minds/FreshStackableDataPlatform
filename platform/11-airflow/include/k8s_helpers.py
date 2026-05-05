"""KubernetesPodOperator-helpers — git-sync, CA-bundle, resources.

Gedeeld door bronze-, governance- en ops-DAGs die nog rauwe K8s-pods runnen
(in tegenstelling tot Cosmos-tasks).
"""
from __future__ import annotations

from kubernetes.client.models import (
    V1Container,
    V1EnvVar,
    V1Volume,
    V1VolumeMount,
    V1ConfigMapVolumeSource,
)

GIT_SYNC_IMAGE = "registry.k8s.io/git-sync/git-sync:v4.2.4"

# Default workspace-volume (emptyDir) waarin git-sync de repo neerzet.
WORKSPACE_VOLUME = "workspace"
WORKSPACE_PATH = "/workspace"
WORKSPACE_REPO = "/workspace/repo"

# CA-bundle voor uitgaande TLS-calls (Trino, Keycloak, OM).
CA_VOLUME = "uwv-ca"
CA_MOUNT = "/etc/uwv-ca"


def workspace_volume() -> V1Volume:
    return V1Volume(name=WORKSPACE_VOLUME, empty_dir={})


def workspace_mount() -> V1VolumeMount:
    return V1VolumeMount(name=WORKSPACE_VOLUME, mount_path=WORKSPACE_PATH)


def ca_volume() -> V1Volume:
    return V1Volume(
        name=CA_VOLUME,
        config_map=V1ConfigMapVolumeSource(name="uwv-ca-bundle"),
    )


def ca_mount() -> V1VolumeMount:
    return V1VolumeMount(name=CA_VOLUME, mount_path=CA_MOUNT, read_only=True)


def git_sync_init(repo_url: str, ref: str = "main") -> V1Container:
    return V1Container(
        name="git-sync",
        image=GIT_SYNC_IMAGE,
        image_pull_policy="IfNotPresent",
        env=[
            V1EnvVar(name="GITSYNC_REPO", value=repo_url),
            V1EnvVar(name="GITSYNC_REF", value=ref),
            V1EnvVar(name="GITSYNC_ROOT", value=WORKSPACE_PATH),
            V1EnvVar(name="GITSYNC_DEPTH", value="1"),
            V1EnvVar(name="GITSYNC_ONE_TIME", value="true"),
        ],
        volume_mounts=[workspace_mount()],
    )


# Standaard pod-resources — klein zodat KubernetesExecutor schaalbaar blijft.
SMALL_POD_RESOURCES = {
    "request_cpu": "100m",
    "request_memory": "256Mi",
    "limit_cpu": "500m",
    "limit_memory": "1Gi",
}
