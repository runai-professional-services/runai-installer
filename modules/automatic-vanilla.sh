#!/bin/bash

automatic_vanilla_install_missing_optional_components() {
    automatic_probe_stack

    local -a part1_flags=(--install-only)
    local -a installed_components=()
    # HAProxy is normally installed later in run_automatic_mode; include it here when missing so
    # --automatic-stop-after prereqs (or failed steps after this batch) still gets ingress on vanilla.
    if [ "$HAVE_HAPROXY" = false ] && [ -n "${AUTO_IP:-}" ]; then
        part1_flags+=(--haproxy --use-haproxy --ip "$AUTO_IP")
        installed_components+=("HAProxy Kubernetes Ingress")
    fi
    [ "$HAVE_PROMETHEUS" = false ] && part1_flags+=(--prometheus)
    [ "$HAVE_PROMETHEUS" = false ] && installed_components+=("Prometheus")
    [ "$HAVE_GPU" = false ] && part1_flags+=(--gpu-operator)
    [ "$HAVE_GPU" = false ] && installed_components+=("NVIDIA GPU Operator")
    [ "$HAVE_NIM" = false ] && part1_flags+=(--nim-operator)
    [ "$HAVE_NIM" = false ] && installed_components+=("NVIDIA NIM Operator")
    # NVIDIA AI Dynamo: not in automatic batch (NGC OCI / entitlements often need manual follow-up). Install with --dynamo when ready.
    [ "$HAVE_KNATIVE" = false ] && part1_flags+=(--knative)
    [ "$HAVE_KNATIVE" = false ] && installed_components+=("Knative")
    [ "$HAVE_LWS" = false ] && part1_flags+=(--lws)
    [ "$HAVE_LWS" = false ] && installed_components+=("LWS")
    [ "$HAVE_MPI" = false ] && part1_flags+=(--mpi-operator)
    [ "$HAVE_MPI" = false ] && installed_components+=("MPI Operator")
    [ "$HAVE_TRAINING" = false ] && part1_flags+=(--training)
    [ "$HAVE_TRAINING" = false ] && installed_components+=("Training Operator")

    if [ "${#part1_flags[@]}" -gt 1 ]; then
        echo -e "\n${BLUE}Installing optional prerequisites (missing on this cluster):${NC}"
        local c
        for c in "${installed_components[@]}"; do
            echo -e "  ${GREEN}•${NC} ${c}"
        done
        echo -e "${BLUE}Sub-installer:${NC} ./runai-installer.sh ${part1_flags[*]}"
        if ! automatic_run_sub_installer "${part1_flags[@]}"; then
            echo -e "${RED}❌ install-only prerequisites step failed${NC}" >&2
            return 1
        fi
        echo -e "${GREEN}Installed:${NC}"
        local c
        for c in "${installed_components[@]}"; do
            echo "  - $c"
        done
    else
        echo -e "\n${GREEN}Optional prerequisites already present${NC}."
    fi
    return 0
}
