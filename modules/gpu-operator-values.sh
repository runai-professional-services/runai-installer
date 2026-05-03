#!/bin/bash
# Resolve which bundled GPU Operator values file to use (Bright CM vs vanilla Kubernetes).
# Sourced by modules/prerequisites.sh and install-k8.sh.
#
# GPU_OPERATOR_DEFAULT_VALUES_FILE — if set, use this path (skips profile logic).
# GPU_OPERATOR_VALUES_PROFILE        — auto | vanilla | bcm (default: auto)
# RUNAI_BCM_CLUSTER                  — true/1 forces bcm profile when profile is auto

runai_gpu_operator_is_bcm_containerd_layout() {
    [ -x /cm/local/apps/containerd/current/bin/containerd ] \
        && [ -f /cm/local/apps/containerd/var/etc/conf.d/nvidia-cri.toml ]
}

# stdout: absolute path to values yaml. $1 = directory containing helm-values/ (usually .../modules).
runai_gpu_operator_values_file_for_host() {
    local modules_dir="${1:?modules dir}"
    local d="${modules_dir}/helm-values"

    if [ -n "${GPU_OPERATOR_DEFAULT_VALUES_FILE:-}" ]; then
        printf '%s' "${GPU_OPERATOR_DEFAULT_VALUES_FILE}"
        return 0
    fi

    case "${GPU_OPERATOR_VALUES_PROFILE:-auto}" in
        bcm)
            printf '%s' "${d}/gpu-operator.bcm.yaml"
            return 0
            ;;
        vanilla)
            printf '%s' "${d}/gpu-operator.vanilla.yaml"
            return 0
            ;;
        auto) ;;
        *)
            printf '%s' "${d}/gpu-operator.vanilla.yaml"
            return 0
            ;;
    esac

    case "${RUNAI_BCM_CLUSTER:-}" in
        1|true|TRUE|yes|YES|Yes)
            printf '%s' "${d}/gpu-operator.bcm.yaml"
            return 0
            ;;
    esac

    if runai_gpu_operator_is_bcm_containerd_layout; then
        printf '%s' "${d}/gpu-operator.bcm.yaml"
        return 0
    fi

    printf '%s' "${d}/gpu-operator.vanilla.yaml"
}

runai_gpu_operator_values_profile_label() {
    local f="$1"
    case "$f" in
        *bcm.yaml) printf '%s' "bcm" ;;
        *vanilla.yaml) printf '%s' "vanilla" ;;
        *) printf '%s' "custom" ;;
    esac
}
