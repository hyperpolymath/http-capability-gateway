#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# setup.sh — Universal setup script for http-capability-gateway
#
# Detects your shell, platform, and installs prerequisites.
# Then hands off to `just setup` for project-specific configuration.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hyperpolymath/http-capability-gateway/main/setup.sh | sh
#   # or after cloning:
#   ./setup.sh
#
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)

set -eu

# ── Colours (safe — uses symbols too per ADJUST contractile) ──
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1 2>/dev/null || true)
    GREEN=$(tput setaf 2 2>/dev/null || true)
    YELLOW=$(tput setaf 3 2>/dev/null || true)
    BLUE=$(tput setaf 4 2>/dev/null || true)
    BOLD=$(tput bold 2>/dev/null || true)
    NC=$(tput sgr0 2>/dev/null || true)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    NC=""
fi

# ── Status Icons ──
INFO="[ ${BLUE}..${NC} ]"
SUCCESS="[ ${GREEN}OK${NC} ]"
ERROR="[ ${RED}!!${NC} ]"
WARN="[ ${YELLOW}??${NC} ]"

log_info() { printf "%b %s\n" "${INFO}" "$*"; }
log_success() { printf "%b %s\n" "${SUCCESS}" "$*"; }
log_error() { printf "%b %s\n" "${ERROR}" "$*" >&2; }
log_warn() { printf "%b %s\n" "${WARN}" "$*"; }

# ── Detection ──
detect_shell() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        echo "zsh"
    elif [ -n "${BASH_VERSION:-}" ]; then
        echo "bash"
    else
        SHELL_PROC=$(ps -p $$ -o comm= 2>/dev/null || echo "unknown")
        echo "${SHELL_PROC}"
    fi
}

detect_platform() {
    OS=$(uname -s 2>/dev/null || echo "unknown")
    ARCH=$(uname -m 2>/dev/null || echo "unknown")
    
    case "${OS}" in
        Linux)
            if [ -f /etc/os-release ]; then
                DISTRO=$(. /etc/os-release && echo "${ID}")
                echo "linux-${DISTRO}-${ARCH}"
            else
                echo "linux-generic-${ARCH}"
            fi
            ;;
        Darwin)
            echo "macos-${ARCH}"
            ;;
        *)
            echo "unknown-${ARCH}"
            ;;
    esac
}

# ── Main ──
main() {
    log_info "Starting http-capability-gateway setup..."
    
    CURRENT_SHELL=$(detect_shell)
    PLATFORM=$(detect_platform)
    
    log_info "Detected: ${CURRENT_SHELL} on ${PLATFORM}"
    
    # Check for core dependencies
    deps="git curl just asdf"
    for dep in ${deps}; do
        if ! command -v "${dep}" >/dev/null 2>&1; then
            log_error "Missing required dependency: ${dep}"
            log_info "Please install ${dep} and run again."
            exit 1
        fi
    done
    
    log_success "Core dependencies present."
    
    # Handoff to just for project-specific setup
    log_info "Handing off to 'just setup'..."
    if just setup; then
        log_success "Setup complete!"
        printf "\n%b Run 'just' to see available commands.\n" "${SUCCESS}"
    else
        log_error "Setup failed during 'just setup'."
        exit 1
    fi
}

main "$@"
