#!/bin/bash

automatic_ocp_print_preconfirm_preview() {
    if declare -F runai_openshift_nfd_status >/dev/null 2>&1 \
        && declare -F runai_openshift_gpu_operator_status >/dev/null 2>&1 \
        && declare -F runai_openshift_knative_serverless_status >/dev/null 2>&1; then
        local nfd gpu kn lbl fmt
        fmt="%-32s"
        nfd="$(runai_openshift_nfd_status)"
        gpu="$(runai_openshift_gpu_operator_status)"
        kn="$(runai_openshift_knative_serverless_status)"
        printf -v lbl "$fmt" "NFD (Node Feature Discovery)"
        echo -e "  ${lbl} →  $(runai_openshift__cstatus "$nfd")  ${YELLOW}(prerequisite for GPU Operator)${NC}"
        printf -v lbl "$fmt" "NVIDIA GPU Operator"
        echo -e "  ${lbl} →  $(runai_openshift__cstatus "$gpu")  ${YELLOW}(Run:ai GPU)${NC}"
        printf -v lbl "$fmt" "Knative (OpenShift Serverless)"
        if [ "$kn" = "present" ]; then
            echo -e "  ${lbl} →  $(runai_openshift__cstatus "$kn")"
        else
            echo -e "  ${lbl} →  ${YELLOW}not detected${NC}  - Inference will not work"
        fi
    elif declare -F runai_openshift_print_recommended_prereq_operators >/dev/null 2>&1; then
        runai_openshift_print_recommended_prereq_operators
    else
        echo "  (openshift.sh not loaded; cannot list operators)"
    fi
}

automatic_ocp_install_missing_optional_components() {
    return 0
}
