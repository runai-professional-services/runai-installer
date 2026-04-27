#!/bin/bash

automatic_vanilla_install_missing_optional_components() {
    automatic_probe_stack

    local -a part1_flags=(--install-only)
    [ "$HAVE_PROMETHEUS" = false ] && part1_flags+=(--prometheus)
    [ "$HAVE_GPU" = false ] && part1_flags+=(--gpu-operator)
    [ "$HAVE_KNATIVE" = false ] && part1_flags+=(--knative)
    [ "$HAVE_LWS" = false ] && part1_flags+=(--lws)
    [ "$HAVE_TRAINING" = false ] && part1_flags+=(--training)

    if [ "${#part1_flags[@]}" -gt 1 ]; then
        echo -e "\n${BLUE}Installing optional prerequisites...${NC}"
        if ! automatic_run_sub_installer "${part1_flags[@]}"; then
            echo -e "${RED}❌ install-only prerequisites step failed${NC}" >&2
            return 1
        fi
    else
        echo -e "\n${GREEN}Optional prerequisites already present${NC}."
    fi
    return 0
}
