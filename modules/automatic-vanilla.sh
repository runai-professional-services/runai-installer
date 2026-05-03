#!/bin/bash

automatic_vanilla_install_missing_optional_components() {
    automatic_probe_stack

    local -a part1_flags=(--install-only)
    local -a installed_components=()
    [ "$HAVE_PROMETHEUS" = false ] && part1_flags+=(--prometheus)
    [ "$HAVE_PROMETHEUS" = false ] && installed_components+=("Prometheus")
    [ "$HAVE_GPU" = false ] && part1_flags+=(--gpu-operator)
    [ "$HAVE_GPU" = false ] && installed_components+=("NVIDIA GPU Operator")
    [ "$HAVE_KNATIVE" = false ] && part1_flags+=(--knative)
    [ "$HAVE_KNATIVE" = false ] && installed_components+=("Knative")
    [ "$HAVE_LWS" = false ] && part1_flags+=(--lws)
    [ "$HAVE_LWS" = false ] && installed_components+=("LWS")
    [ "$HAVE_MPI" = false ] && part1_flags+=(--mpi-operator)
    [ "$HAVE_MPI" = false ] && installed_components+=("MPI Operator")
    [ "$HAVE_TRAINING" = false ] && part1_flags+=(--training)
    [ "$HAVE_TRAINING" = false ] && installed_components+=("Training Operator")

    if [ "${#part1_flags[@]}" -gt 1 ]; then
        echo -e "\n${BLUE}Installing optional prerequisites...${NC}"
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
