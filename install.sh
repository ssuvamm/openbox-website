#!/usr/bin/env bash
# ==========================================
# OpenBox - One-Line Installer
# curl -fsSL https://openbox.crushcodeworks.com/install.sh | bash
#
# Supports both VPS (Ubuntu/Debian) and NAS (UGREEN, Synology, etc.)
#
# Self-Hosted Privacy Stack by Crush Code Works
# ==========================================

set -euo pipefail

# Note: deliberately NOT named DOWNLOAD_URL — that collides with the
# variable Docker's own get-docker.sh uses for its repo base URL, and
# Docker will pick up our override and try to fetch its GPG key from it.
OB_DOWNLOAD_URL="${OB_DOWNLOAD_URL:-https://openbox.crushcodeworks.com/openbox.tar.gz}"
# Baked SHA256 of the release tarball. Used when the .sha256 fetch fails or returns malformed data.
# Computed at build time. Must match the tarball at the above URL.
OB_BAKED_SHA256="d4f35e638328553e68e41cf8aa9756f063e2df8c240d907f8a1a742095207432"
VERSION_URL="https://openbox.crushcodeworks.com/version.txt"

# Public half of the OpenBox release signing key, baked into every
# shipped copy of install.sh at release time.
OB_BAKED_RELEASE_PUBLIC_KEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAqoPFFIkhxN0sSoUsTWpr5FVHNQ/OtLuTg57HxEQeCXo=
-----END PUBLIC KEY-----'

# Defaults (overridden by flags and detection)
INSTALL_DIR=""
FORCE_NAS=false
IS_NAS=false
NAS_TYPE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[OpenBox]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OpenBox]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[OpenBox]${NC} $*"; }
log_error() { echo -e "${RED}[OpenBox]${NC} $*"; }

# --- Distro abstraction (multi-distro support) ---
detect_distro_family() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case " ${ID_LIKE:-} " in
            *" debian "*|*" ubuntu "*) echo "debian"; return ;;
            *" rhel "*|*" fedora "*|*" centos "*) echo "rhel"; return ;;
            *" arch "*) echo "arch"; return ;;
        esac
        case "${ID:-}" in
            debian|ubuntu|linuxmint|pop|kali|raspbian|elementary|pureos|deepin) echo "debian" ;;
            rocky|almalinux|fedora|rhel|centos|ol|amzn) echo "rhel" ;;
            arch|manjaro|endeavouros|arcolinux|garuda) echo "arch" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

# Install packages using whatever package manager is on this box.
pkg_install() {
    local family
    family="$(detect_distro_family)"
    local pkgs=("$@")
    local pm_log
    pm_log="$(mktemp -t ob-pkg-XXXXXX.log)"
    _pm_die() {
        log_error "Package install failed (exit $1). Last 20 lines of pkg-mgr output:"
        tail -n20 "${pm_log}" 2>/dev/null | sed 's/^/  /'
        log_error "Full log: ${pm_log}"
        return "$1"
    }
    case "${family}" in
        debian)
            apt-get update -qq >>"${pm_log}" 2>&1 || true
            apt-get install -y -qq "${pkgs[@]}" >>"${pm_log}" 2>&1 || _pm_die $?
            ;;
        rhel)
            local rhel_pkgs=()
            local need_epel=false
            for p in "${pkgs[@]}"; do
                case "${p}" in
                    whiptail) rhel_pkgs+=(newt) ;;
                    ufw|fail2ban) rhel_pkgs+=("${p}"); need_epel=true ;;
                    *) rhel_pkgs+=("${p}") ;;
                esac
            done
            if [[ "${need_epel}" == "true" ]] && ! rpm -q epel-release >/dev/null 2>&1; then
                dnf install -y -q epel-release >>"${pm_log}" 2>&1 || true
            fi
            dnf install -y -q --allowerasing "${rhel_pkgs[@]}" >>"${pm_log}" 2>&1 || _pm_die $?
            ;;
        arch)
            local arch_pkgs=()
            for p in "${pkgs[@]}"; do
                case "${p}" in
                    whiptail) arch_pkgs+=(libnewt) ;;
                    *) arch_pkgs+=("${p}") ;;
                esac
            done
            pacman -Sy --noconfirm --needed "${arch_pkgs[@]}" >>"${pm_log}" 2>&1 || _pm_die $?
            ;;
        *)
            log_warn "Unknown distro family — couldn't install: $*"
            log_warn "Run manually then re-run the installer: $*"
            return 1
            ;;
    esac
}

# Install Docker using the right path per distro.
install_docker_pkg() {
    if [[ "${OB_TEST_MODE:-0}" == "1" ]]; then
        log_info "[TEST_MODE] Skipping real Docker install + systemctl."
        return 0
    fi
    local family
    family="$(detect_distro_family)"
    local docker_log
    docker_log="$(mktemp -t ob-docker-XXXXXX.log)"
    case "${family}" in
        debian|rhel)
            if ! (unset DOWNLOAD_URL; curl -fsSL https://get.docker.com | sh) >>"${docker_log}" 2>&1; then
                log_error "Docker install failed. Last 20 lines of get-docker.sh output:"
                tail -n20 "${docker_log}" 2>/dev/null | sed 's/^/  /'
                log_error "Full log: ${docker_log}"
                exit 1
            fi
            ;;
        arch)
            if ! pacman -Sy --noconfirm --needed docker docker-buildx docker-compose >>"${docker_log}" 2>&1; then
                log_error "Docker install failed. Last 20 lines of pacman output:"
                tail -n20 "${docker_log}" 2>/dev/null | sed 's/^/  /'
                log_error "Full log: ${docker_log}"
                exit 1
            fi
            ;;
        *)
            log_error "Unknown distro — install Docker manually, then re-run this installer."
            exit 1
            ;;
    esac
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker 2>/dev/null || true
}

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --install-dir=*)
            INSTALL_DIR="${1#*=}"
            shift
            ;;
        --nas)
            FORCE_NAS=true
            shift
            ;;
        *)
            log_error "Unknown flag: $1"
            echo "Usage: install.sh [--install-dir /path] [--nas]"
            exit 1
            ;;
    esac
done

# --- Banner ---
banner_supports_fancy() {
    case "${COLORTERM:-}" in truecolor|24bit) ;; *) return 1 ;; esac
    case "${LANG:-}${LC_ALL:-}" in *UTF-8*|*utf8*|*utf-8*) ;; *) return 1 ;; esac
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    [[ "$cols" -ge 78 ]] || return 1
    return 0
}

# Brand colors — teal primary with purple accent
TEAL='\033[38;2;0;204;204m'       # OpenBox teal #00CCCC
TEAL2='\033[38;2;0;180;180m'      # teal highlight
PURPLE='\033[38;2;124;92;255m'   # accent purple
PURPLE2='\033[38;2;167;139;250m' # purple highlight
W='\033[38;2;230;230;240m'       # off-white (case top)
G='\033[38;2;120;120;140m'       # gray (drive slot shadow)
DIM='\033[2m'

echo ""
if banner_supports_fancy; then
    printf "    ${TEAL2}◆${NC}              ${PURPLE}${BOLD}  ____                   _    ____            ${NC}\n"
    printf "   ${TEAL}╱│╲${NC}             ${PURPLE}${BOLD} / ___| _ __   __ _ _ __| | _| __ )  _____  __${NC}\n"
    printf "  ${PURPLE}┌─${W}─┬─${PURPLE}─┐${NC}           ${PURPLE}${BOLD} \\\\___ \\\\| '_ \\\\ / _\` | '__| |/ /  _ \\\\ / _ \\\\ \\\\// /${NC}\n"
    printf "  ${PURPLE}│ ${G}░${W}│${G}░${PURPLE} │${NC}           ${PURPLE}${BOLD}  ___) | |_) | (_| | |  |   <| |_) | (_) >  < ${NC}\n"
    printf "  ${PURPLE}│ ${G}░${W}│${G}░${PURPLE} │${NC}           ${PURPLE}${BOLD} |____/| .__/ \\\\__,_|_|  |_|\\\\_\\\\____/ \\\\___/_/\\\\_\\\\${NC}\n"
    printf "  ${PURPLE}│ ${G}░${W}│${G}░${PURPLE} │${NC}           ${PURPLE}${BOLD}       |_|                                     ${NC}\n"
    printf "  ${PURPLE}└─────┘${NC}\n"
    echo ""
    printf " ${BOLD}The easiest, most user-friendly self-hosting stack anywhere.${NC}\n"
    printf " ${PURPLE2}Created by Crush Code Works${NC} ${DIM}·${NC} ${PURPLE2}crushcodeworks.com${NC}\n"
else
    echo -e "${CYAN}"
    echo "  ____                   _    ____            "
    echo " / ___| _ __   __ _ _ __| | _| __ )  _____  __"
    echo " \\___ \\| '_ \\ / _\` | '__| |/ /  _ \\ / _ \\ \\/ /"
    echo "  ___) | |_) | (_| | |  |   <| |_) | (_) >  < "
    echo " |____/| .__/ \\__,_|_|  |_|\\_\\____/ \\___/_/\\_\\"
    echo "       |_|                                     "
    echo -e "${NC}"
    echo -e " ${BOLD}The easiest, most user-friendly self-hosting stack anywhere.${NC}"
    echo -e " Created by Crush Code Works | crushcodeworks.com"
fi
echo ""

# --- Environment Detection ---
detect_nas() {
    if [[ -f /etc/ugos ]] || [[ -f /etc/ugos-release ]] || \
       [[ -d /etc/ugos.d ]] || grep -qi "ugos\|ugreen" /etc/os-release 2>/dev/null; then
        NAS_TYPE="ugreen"
        return 0
    fi
    if grep -q "^OS_VERSION=" /etc/os-release 2>/dev/null && grep -q "^OS_IS_BETA=" /etc/os-release 2>/dev/null; then
        NAS_TYPE="ugreen"
        return 0
    fi
    if [[ "$(hostname 2>/dev/null)" =~ ^DXP[0-9]+ ]] && [[ -d /volume1/@docker ]]; then
        NAS_TYPE="ugreen"
        return 0
    fi

    if command -v docker &>/dev/null && ! command -v apt-get &>/dev/null; then
        NAS_TYPE="generic"
        log_warn "Unsupported NAS detected. OpenBox officially supports UGREEN NASync."
        log_warn "Continuing anyway — it may work, but support is limited."
        return 0
    fi

    return 1
}

suggest_install_dir() {
    case "${NAS_TYPE}" in
        ugreen)
            echo "/opt/openbox"
            ;;
        *)
            echo "/opt/openbox"
            ;;
    esac
}

suggest_data_dir() {
    if [[ -n "${OB_DATA_DIR:-}" ]]; then
        echo "${OB_DATA_DIR}"
        return
    fi
    case "${NAS_TYPE}" in
        ugreen)
            if [[ -d /volume1 ]]; then
                echo "/volume1/openbox-data"
                return
            fi
            ;;
    esac
    echo "${INSTALL_DIR}/data"
}

if [[ "${FORCE_NAS}" == true ]]; then
    IS_NAS=true
    if [[ -z "${NAS_TYPE}" ]]; then
        detect_nas || NAS_TYPE="generic"
    fi
    log_info "NAS mode forced."
elif detect_nas; then
    IS_NAS=true
    log_info "NAS detected: ${NAS_TYPE}"
fi

if [[ "${IS_NAS}" == true ]]; then
    log_info "Running in NAS mode (${NAS_TYPE})"
    echo ""
    log_warn "NAS users: keep internet access ON during install."
    log_warn "OpenBox needs the internet to:"
    log_warn "  1. Pull Docker images during install"
    log_warn "  2. Activate your free personal-use license key (auto-updates)"
    log_warn "Re-block outbound internet only AFTER you've logged in, registered"
    log_warn "your license, and finished the setup wizard."
    log_warn "Full details: https://crushcodeworks.com/docs.html"
    echo ""
else
    log_info "Running in VPS mode"
fi

# --- Network profile detection ---
detect_environment() {
    OB_PROFILE=""
    OB_PROFILE_REASONS=""

    case "${OPENBOX_PROFILE:-}" in
        nas|private|public)
            OB_PROFILE="${OPENBOX_PROFILE}"
            OB_PROFILE_REASONS="manual override via OPENBOX_PROFILE"
            return 0
            ;;
    esac

    if [[ "${IS_NAS}" == "true" ]]; then
        OB_PROFILE="nas"
        OB_PROFILE_REASONS="NAS detected: ${NAS_TYPE:-unknown}"
        return 0
    fi

    local reasons=()
    local cloud_detected=""

    if curl -fsS --connect-timeout 1 --max-time 2 \
            http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null \
            | grep -qE '^i-' ; then
        cloud_detected="aws"
    elif curl -fsS --connect-timeout 1 --max-time 2 \
            http://169.254.169.254/metadata/v1/id 2>/dev/null \
            | grep -qE '^[0-9]+$' ; then
        cloud_detected="digitalocean"
    elif curl -fsS --connect-timeout 1 --max-time 2 \
            http://169.254.169.254/hetzner/v1/metadata/instance-id 2>/dev/null \
            | grep -qE '^[0-9]+$' ; then
        cloud_detected="hetzner"
    elif curl -fsS --connect-timeout 1 --max-time 2 \
            -H "Metadata: true" \
            "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null \
            | grep -q "azEnvironment" ; then
        cloud_detected="azure"
    elif curl -fsS --connect-timeout 1 --max-time 2 \
            -H "Metadata-Flavor: Google" \
            http://metadata.google.internal/computeMetadata/v1/instance/id 2>/dev/null \
            | grep -qE '^[0-9]+$' ; then
        cloud_detected="gcp"
    fi

    if [[ -n "${cloud_detected}" ]]; then
        reasons+=("cloud metadata service detected: ${cloud_detected}")
    fi

    local default_src=""
    if command -v ip &>/dev/null; then
        default_src=$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' \
            || true)
    fi

    local is_private=false
    if [[ -n "${default_src}" ]]; then
        if [[ "${default_src}" =~ ^10\. ]] \
            || [[ "${default_src}" =~ ^192\.168\. ]] \
            || [[ "${default_src}" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] \
            || [[ "${default_src}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] \
            || [[ "${default_src}" =~ ^127\. ]] \
            || [[ "${default_src}" =~ ^169\.254\. ]]; then
            is_private=true
            reasons+=("default-route source IP is private/CGNAT: ${default_src}")
        else
            reasons+=("default-route source IP is publicly routable: ${default_src}")
        fi
    else
        reasons+=("could not determine default-route source IP")
    fi

    if [[ -n "${cloud_detected}" ]]; then
        OB_PROFILE="public"
    elif [[ "${is_private}" == "true" ]]; then
        OB_PROFILE="private"
    elif [[ -n "${default_src}" ]]; then
        OB_PROFILE="public"
    else
        OB_PROFILE="private"
        reasons+=("defaulting to private (network classification inconclusive)")
    fi

    OB_PROFILE_REASONS="$(IFS=';'; echo "${reasons[*]}")"
    return 0
}

detect_environment
log_info "Network profile: ${OB_PROFILE} (${OB_PROFILE_REASONS})"
echo ""

# Set install directory
if [[ -z "${INSTALL_DIR}" ]]; then
    if [[ "${IS_NAS}" == true ]]; then
        INSTALL_DIR=$(suggest_install_dir)
        log_info "Suggested install directory: ${INSTALL_DIR}"
    else
        INSTALL_DIR="/opt/openbox"
    fi
fi

# Set data directory
OB_DATA_DIR_VALUE=$(suggest_data_dir)
log_info "Data directory (media/photos/books/manga): ${OB_DATA_DIR_VALUE}"

# --- Pre-flight Checks ---
free_port_53_if_needed() {
    if ! command -v systemctl &>/dev/null; then return 0; fi
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then return 0; fi
    if command -v ss &>/dev/null; then
        if ! ss -tulpn 2>/dev/null | grep -qE '[:.]53[[:space:]]'; then return 0; fi
    fi
    log_info "Freeing host port 53 for Pi-hole (disabling systemd-resolved stub listener)"
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/openbox-no-stub.conf <<'EOF'
# OpenBox: Pi-hole needs host port 53. Turn off the systemd-resolved stub
# listener so the port is free, and point /etc/resolv.conf at a real upstream.
[Resolve]
DNSStubListener=no
DNS=1.1.1.1 9.9.9.9
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
        if [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
            local _resolv_backup="/etc/resolv.conf.openbox-backup-$(date +%s)"
            mv /etc/resolv.conf "${_resolv_backup}" 2>/dev/null \
                && log_info "Existing /etc/resolv.conf backed up to ${_resolv_backup}"
        else
            rm -f /etc/resolv.conf
        fi
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
    log_ok "Port 53 freed; host DNS now uses 1.1.1.1 / 9.9.9.9 upstream"
}

if [[ "${IS_NAS}" != true ]]; then
    free_port_53_if_needed
fi

# Root / Docker permission check
if [[ "${IS_NAS}" == true ]]; then
    if [[ $EUID -ne 0 ]]; then
        if docker info &>/dev/null 2>&1; then
            log_ok "Docker access confirmed (non-root)."
        else
            log_error "Cannot access Docker. Re-run the installer with sudo:"
            echo "  curl -fsSL https://openbox.crushcodeworks.com/install.sh | sudo bash"
            echo ""
            echo "  (UGOS's busybox blocks 'newgrp docker', so the usual"
            echo "   'add user to docker group' workaround does not work here.)"
            exit 1
        fi
    fi
else
    if [[ $EUID -ne 0 ]]; then
        log_error "This installer must be run as root."
        echo "  Try: sudo bash -c \"\$(curl -sSL https://openbox.crushcodeworks.com/install.sh)\""
        exit 1
    fi
fi

# Time-skew check
_server_date=$(curl -sI --max-time 8 https://www.cloudflare.com 2>/dev/null \
    | grep -i "^date:" | head -1 | sed 's/^[Dd]ate: //I' | tr -d '\r')
if [[ -n "${_server_date}" ]]; then
    _server_epoch=$(date -d "${_server_date}" +%s 2>/dev/null)
    _local_epoch=$(date +%s)
    if [[ -n "${_server_epoch}" ]]; then
        _drift=$(( _server_epoch - _local_epoch ))
        _abs_drift=${_drift#-}
        if [[ "${_abs_drift}" -gt 300 ]]; then
            log_warn "System clock is ${_drift}s off compared to Cloudflare's reference."
            log_warn "  This will break TLS handshakes (cert validation depends on the clock)."
            log_warn "  Fix:  sudo timedatectl set-ntp true && sudo systemctl restart systemd-timesyncd"
            log_warn "  Then re-run install.sh."
        else
            log_ok "System clock is in sync (${_drift}s off Cloudflare's reference)"
        fi
    fi
fi
unset _server_date _server_epoch _local_epoch _drift _abs_drift

# OS check
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    case "${ID}" in
        ubuntu|debian)
            log_info "Detected: ${PRETTY_NAME}"
            ;;
        *)
            if [[ "${IS_NAS}" == true ]]; then
                log_info "Detected: ${PRETTY_NAME:-Unknown OS} (NAS mode - this is fine)"
            else
                log_warn "Detected: ${PRETTY_NAME} - OpenBox is designed for Ubuntu/Debian."
                log_warn "Continuing anyway, but some features may not work."
            fi
            ;;
    esac
else
    if [[ "${IS_NAS}" == true ]]; then
        log_info "OS detection skipped (NAS mode)"
    else
        log_error "Unsupported operating system."
        exit 1
    fi
fi

# Check RAM
if [[ -f /proc/meminfo ]]; then
    total_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [[ ${total_ram_mb} -lt 2048 ]]; then
        log_error "Insufficient RAM: ${total_ram_mb}MB detected, minimum 2GB required."
        exit 1
    elif [[ ${total_ram_mb} -lt 4096 ]]; then
        log_warn "RAM: ${total_ram_mb}MB detected. 4GB+ recommended for most modules."
    elif [[ ${total_ram_mb} -lt 8192 ]]; then
        log_warn "RAM: ${total_ram_mb}MB detected. 8GB+ recommended for media modules."
    fi
fi

# Check disk space
parent_dir=$(dirname "${INSTALL_DIR}")
mkdir -p "${parent_dir}" 2>/dev/null || true
if [[ -d "${parent_dir}" ]]; then
    available_gb=$(df -BG "${parent_dir}" 2>/dev/null | awk 'NR==2 {print int($4)}')
    if [[ ${available_gb} -lt 20 ]]; then
        log_warn "Low disk space: ${available_gb}GB available at ${parent_dir}. 20GB+ recommended."
    fi
fi

# Install-dir writability check (NAS, non-root)
if [[ "${IS_NAS}" == true && $EUID -ne 0 ]]; then
    if [[ -d "${INSTALL_DIR}" ]]; then
        if [[ ! -w "${INSTALL_DIR}" ]]; then
            log_error "Cannot write to ${INSTALL_DIR}. Re-run the installer with sudo:"
            echo "  curl -fsSL https://openbox.crushcodeworks.com/install.sh | sudo bash"
            exit 1
        fi
    else
        if [[ ! -d "${parent_dir}" || ! -w "${parent_dir}" ]]; then
            log_error "Cannot create ${INSTALL_DIR} — ${parent_dir} is not writable by $(id -un)."
            log_error "Re-run the installer with sudo:"
            echo "  curl -fsSL https://openbox.crushcodeworks.com/install.sh | sudo bash"
            exit 1
        fi
    fi
fi

# --- Install Dependencies ---
if [[ "${IS_NAS}" == true ]]; then
    log_info "NAS mode: skipping system package installation."
    for tool in curl jq openssl; do
        if ! command -v "${tool}" &>/dev/null; then
            log_warn "Tool '${tool}' not found. Some features may not work."
        fi
    done
    if ! command -v whiptail &>/dev/null; then
        log_info "whiptail not found -- setup wizard will use plain text prompts."
    fi
else
    _distro_family="$(detect_distro_family)"
    log_info "Installing system dependencies (detected: ${_distro_family})..."
    if [[ "${_distro_family}" == "unknown" ]]; then
        log_warn "Couldn't detect distro family — skipping pkg-manager install."
        log_warn "Make sure curl, jq, openssl, and whiptail are present, then re-run."
    else
        pkg_install curl jq openssl whiptail
        log_ok "System dependencies installed (${_distro_family})."
    fi
fi

# --- Install Docker ---
if [[ "${IS_NAS}" == true ]]; then
    if command -v docker &>/dev/null; then
        log_ok "Docker already installed: $(docker --version)"
    else
        log_error "Docker is not installed. On a NAS, install Docker through your NAS package manager."
        echo "  UGREEN: Install Docker via UGOS App Center"
        exit 1
    fi
else
    if command -v docker &>/dev/null; then
        log_ok "Docker already installed: $(docker --version)"
    elif [[ "${OB_TEST_MODE:-0}" == "1" ]]; then
        log_info "[TEST_MODE] Docker not present, skipping install."
    else
        log_info "Installing Docker via distro-appropriate path..."
        install_docker_pkg
        log_ok "Docker installed: $(docker --version)"
    fi
fi

# Verify Docker Compose v2
if [[ "${OB_TEST_MODE:-0}" == "1" ]]; then
    log_info "[TEST_MODE] Skipping Docker Compose version check."
elif docker compose version &>/dev/null; then
    COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "0.0.0")
    log_ok "Docker Compose: ${COMPOSE_VER}"
    COMPOSE_MAJOR=$(echo "${COMPOSE_VER}" | cut -d. -f1 | tr -cd '0-9')
    if [[ "${COMPOSE_MAJOR}" -lt 2 ]]; then
        log_warn "Docker Compose ${COMPOSE_VER} is older than v2.x. Some features may not work."
        log_warn "OpenBox uses 'deploy.resources.limits' and 'profiles' which require Compose v2.x."
        if [[ "${IS_NAS}" == true ]]; then
            log_warn "Update Docker via your NAS package manager for full compatibility."
        fi
    fi
else
    log_error "Docker Compose v2 not found. Please install Docker Compose plugin."
    exit 1
fi

# --- Download OpenBox ---
OB_UPGRADE_MODE=false
if [[ -f "${INSTALL_DIR}/openbox" ]] && [[ -f "${INSTALL_DIR}/VERSION" ]]; then
    current_ver=$(cat "${INSTALL_DIR}/VERSION" 2>/dev/null || echo "unknown")
    log_info "Existing OpenBox install found (v${current_ver}). Upgrading via atomic rename-swap — .env, state/, and module data are preserved."
    OB_UPGRADE_MODE=true
elif [[ -d "${INSTALL_DIR}" ]] && [[ "$(ls -A "${INSTALL_DIR}" 2>/dev/null)" ]]; then
    log_warn "Existing (non-OpenBox) directory found at ${INSTALL_DIR}"
    log_info "Backing up to ${INSTALL_DIR}.bak.$(date +%s)"
    mv "${INSTALL_DIR}" "${INSTALL_DIR}.bak.$(date +%s)"
fi

log_info "Downloading OpenBox..."
tmp_tar=$(mktemp)
if ! curl -fsSL "${OB_DOWNLOAD_URL}" -o "${tmp_tar}"; then
    log_error "Failed to download OpenBox. Check your internet connection."
    log_error "URL: ${OB_DOWNLOAD_URL}"
    rm -f "${tmp_tar}"
    exit 1
fi

# --- Integrity + authenticity verification ---
ob_sha256_hex() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo ""
    fi
}

log_info "Verifying release integrity..."
expected_digest=$(curl -fsSL "${OB_DOWNLOAD_URL}.sha256" 2>/dev/null | awk '{print $1}' | tr -d '[:space:]' || true)
actual_digest=$(ob_sha256_hex "${tmp_tar}")
if [[ -z "${expected_digest}" ]] || [[ ! "${expected_digest}" =~ ^[a-f0-9]{64}$ ]]; then
    # .sha256 file not available on static-serve host (404) — fall back to baked hash.
    # This happens on Coolify static deployments that don't pick up non-git-tracked files.
    if [[ -n "${OB_BAKED_SHA256:-}" ]]; then
        expected_digest="${OB_BAKED_SHA256}"
        log_warn "Release digest file (.sha256) not available — using baked SHA256 for integrity check."
    else
        log_error "Release digest file missing or malformed and no baked SHA256 available."
        rm -f "${tmp_tar}"
        exit 1
    fi
fi
if [[ -z "${actual_digest}" ]]; then
    log_warn "No sha256 tool available — skipping integrity check."
elif [[ "${actual_digest}" != "${expected_digest}" ]]; then
    log_error "The OpenBox download doesn't match the published checksum — it may be corrupted or tampered with."
    rm -f "${tmp_tar}"
    exit 1
else
    log_ok "SHA256 digest verified"
fi

# ed25519 signature verification
if [[ "${OB_ALLOW_UNSIGNED_INSTALL:-false}" == "true" ]]; then
    log_warn "OB_ALLOW_UNSIGNED_INSTALL=true — skipping ed25519 signature verification."
else
    if ! command -v openssl &>/dev/null; then
        log_info "openssl not found — installing for signature verification..."
        pkg_install openssl >/dev/null 2>&1 || true
        if ! command -v openssl &>/dev/null && command -v apk &>/dev/null; then
            apk add --no-cache openssl >/dev/null 2>&1 || true
        fi
    fi
    if ! command -v openssl &>/dev/null; then
        log_error "openssl is required for release signature verification but is not available."
        rm -f "${tmp_tar}"
        exit 1
    fi

    # OpenSSL version check
    ob_openssl_version=$(openssl version 2>/dev/null | awk '{print $2}')
    ob_openssl_major=$(echo "${ob_openssl_version}" | cut -d. -f1)
    ob_openssl_minor=$(echo "${ob_openssl_version}" | cut -d. -f2)
    ob_openssl_patch=$(echo "${ob_openssl_version}" | cut -d. -f3 | sed 's/[^0-9].*//')
    if [[ -n "${ob_openssl_major}" ]] && {
        [[ "${ob_openssl_major}" -lt 1 ]] || \
        [[ "${ob_openssl_major}" -eq 1 && "${ob_openssl_minor}" -lt 1 ]] || \
        [[ "${ob_openssl_major}" -eq 1 && "${ob_openssl_minor}" -eq 1 && "${ob_openssl_patch:-0}" -lt 1 ]];
    }; then
        log_error "Your OpenSSL version (${ob_openssl_version}) is too old to verify ed25519 release signatures."
        log_error "ed25519 verification requires OpenSSL 1.1.1+."
        rm -f "${tmp_tar}"
        exit 1
    fi
    unset ob_openssl_version ob_openssl_major ob_openssl_minor ob_openssl_patch

    OB_PUBKEY_FILE="${OB_RELEASE_PUBLIC_KEY_FILE:-}"
    tmp_pubkey=""
    if [[ -z "${OB_PUBKEY_FILE}" ]] && [[ -f "/etc/openbox/release-public.pem" ]]; then
        OB_PUBKEY_FILE="/etc/openbox/release-public.pem"
    fi
    if [[ -z "${OB_PUBKEY_FILE}" ]]; then
        tmp_pubkey=$(mktemp)
        printf '%s\n' "${OB_BAKED_RELEASE_PUBLIC_KEY_PEM}" > "${tmp_pubkey}"
        OB_PUBKEY_FILE="${tmp_pubkey}"
    fi

    tmp_sig=$(mktemp)
    # If .sig is not available (404), skip ed25519 verification but require SHA256
    if ! curl -fsSL -o /dev/null -w "%{http_code}" "${OB_DOWNLOAD_URL}.sig" 2>/dev/null | grep -q "200"; then
        log_warn "Release signature (.sig) not available — skipping ed25519 verification."
        log_warn "SHA256 integrity check still runs. Install is safe but not supply-chain signed."
        rm -f "${tmp_tar}" "${tmp_sig}"
        [[ -n "${tmp_pubkey}" ]] && rm -f "${tmp_pubkey}"
        # Jump to post-signature section (don't try openssl verify)
        OB_SIG_MISSING=true
    else
        if ! curl -fsSL "${OB_DOWNLOAD_URL}.sig" -o "${tmp_sig}" 2>/dev/null; then
            log_error "Release signature download failed. Refusing to install."
            rm -f "${tmp_tar}" "${tmp_sig}"
            [[ -n "${tmp_pubkey}" ]] && rm -f "${tmp_pubkey}"
            exit 1
        fi
        OB_SIG_MISSING=false
    fi
    if [[ "${OB_SIG_MISSING:-false}" == "false" ]] && openssl pkeyutl -verify -pubin -inkey "${OB_PUBKEY_FILE}" \
            -rawin -in "${tmp_tar}" -sigfile "${tmp_sig}" &>/dev/null; then
        log_ok "ed25519 signature verified"
    else
        log_error "ed25519 signature verification FAILED. Release is not authentic."
        rm -f "${tmp_tar}" "${tmp_sig}"
        [[ -n "${tmp_pubkey}" ]] && rm -f "${tmp_pubkey}"
        exit 1
    fi
    rm -f "${tmp_sig}"
    [[ -n "${tmp_pubkey}" ]] && rm -f "${tmp_pubkey}"
fi

# --- Extract ---
if [[ "${OB_UPGRADE_MODE}" == "true" ]]; then
    OB_TS=$(date +%s)
    OB_STAGING="${INSTALL_DIR}.new-${OB_TS}"
    OB_ROLLBACK="${INSTALL_DIR}.rollback-${OB_TS}"

    rm -rf "${OB_STAGING}"
    mkdir -p "${OB_STAGING}"
    if ! tar xzf "${tmp_tar}" -C "${OB_STAGING}" --strip-components=1 2>/dev/null; then
        if ! tar xzf "${tmp_tar}" -C "${OB_STAGING}"; then
            rm -rf "${OB_STAGING}"
            rm -f "${tmp_tar}"
            log_error "Upgrade aborted: failed to extract release tarball. Live install untouched."
            exit 1
        fi
    fi
    rm -f "${tmp_tar}"

    for required in openbox VERSION dashboard modules; do
        if [[ ! -e "${OB_STAGING}/${required}" ]]; then
            rm -rf "${OB_STAGING}"
            log_error "Upgrade aborted: staged release is missing ${required}. Live install untouched."
            exit 1
        fi
    done

    if [[ -x "${INSTALL_DIR}/openbox" ]]; then
        log_info "Stopping running containers for a safe upgrade snapshot..."
        "${INSTALL_DIR}/openbox" down 2>&1 | tail -5 || log_warn "openbox down had warnings — continuing."
    fi

    docker image rm openbox-openbox-dashboard >/dev/null 2>&1 || true
    docker image rm openbox_openbox-dashboard >/dev/null 2>&1 || true

    OB_MV_SRC=()
    OB_MV_DST=()

    _ob_move_userdata() {
        local src="$1" dst="$2"
        [[ -e "$src" ]] || return 0
        [[ -e "$dst" ]] && rm -rf "$dst"
        local dst_parent
        dst_parent="$(dirname "$dst")"
        [[ -d "$dst_parent" ]] || mkdir -p "$dst_parent"
        if ! mv "$src" "$dst"; then
            return 1
        fi
        OB_MV_SRC+=("$src")
        OB_MV_DST+=("$dst")
        return 0
    }

    _ob_undo_moves_to_live() {
        local i
        for ((i=${#OB_MV_SRC[@]}-1; i>=0; i--)); do
            local src="${OB_MV_SRC[$i]}" dst="${OB_MV_DST[$i]}"
            [[ -e "$dst" ]] || continue
            mv "$dst" "$src" 2>/dev/null || log_warn "Could not restore $dst → $src"
        done
        OB_MV_SRC=()
        OB_MV_DST=()
    }

    _ob_undo_moves_to_rollback() {
        local i
        for ((i=${#OB_MV_SRC[@]}-1; i>=0; i--)); do
            local src="${OB_MV_SRC[$i]}" dst="${OB_MV_DST[$i]}"
            local rel="${src#${INSTALL_DIR}/}"
            local rollback_dst="${OB_ROLLBACK}/${rel}"
            local rollback_parent
            rollback_parent="$(dirname "$rollback_dst")"
            [[ -d "$rollback_parent" ]] || mkdir -p "$rollback_parent"
            [[ -e "$rollback_dst" ]] && rm -rf "$rollback_dst"
            [[ -e "$dst" ]] || continue
            mv "$dst" "$rollback_dst" 2>/dev/null || log_warn "Could not restore $dst → $rollback_dst"
        done
        OB_MV_SRC=()
        OB_MV_DST=()
    }

    _ob_abort_upgrade_live() {
        log_error "$1"
        _ob_undo_moves_to_live
        rm -rf "${OB_STAGING}"
        exit 1
    }

    _ob_move_userdata "${INSTALL_DIR}/.env" "${OB_STAGING}/.env" \
        || _ob_abort_upgrade_live "Upgrade aborted: could not move .env into staging. Live install untouched."
    _ob_move_userdata "${INSTALL_DIR}/state" "${OB_STAGING}/state" \
        || _ob_abort_upgrade_live "Upgrade aborted: could not move state/ into staging. Live install untouched."
    _ob_move_userdata "${INSTALL_DIR}/backups" "${OB_STAGING}/backups" \
        || _ob_abort_upgrade_live "Upgrade aborted: could not move backups/ into staging. Live install untouched."
    _ob_move_userdata "${INSTALL_DIR}/data" "${OB_STAGING}/data" \
        || _ob_abort_upgrade_live "Upgrade aborted: could not move data/ into staging. Live install untouched."

    if [[ -d "${INSTALL_DIR}/modules" ]]; then
        for mdir in "${INSTALL_DIR}"/modules/*/config; do
            [[ -d "${mdir}" ]] || continue
            mname=$(basename "$(dirname "${mdir}")")
            [[ -d "${OB_STAGING}/modules/${mname}" ]] || mkdir -p "${OB_STAGING}/modules/${mname}"
            _ob_move_userdata "${mdir}" "${OB_STAGING}/modules/${mname}/config" \
                || _ob_abort_upgrade_live "Upgrade aborted: could not move ${mname}/config into staging."
        done
        for mdir in "${INSTALL_DIR}"/modules/*/data \
                    "${INSTALL_DIR}"/modules/*/media \
                    "${INSTALL_DIR}"/modules/*/storage \
                    "${INSTALL_DIR}"/modules/*/backups; do
            [[ -d "${mdir}" ]] || continue
            mname=$(basename "$(dirname "${mdir}")")
            msubdir=$(basename "${mdir}")
            [[ -d "${OB_STAGING}/modules/${mname}" ]] || mkdir -p "${OB_STAGING}/modules/${mname}"
            _ob_move_userdata "${mdir}" "${OB_STAGING}/modules/${mname}/${msubdir}" \
                || _ob_abort_upgrade_live "Upgrade aborted: could not move ${mname}/${msubdir} into staging."
        done
    fi

    if ! mv "${INSTALL_DIR}" "${OB_ROLLBACK}"; then
        log_error "Upgrade aborted: could not move live install aside."
        _ob_undo_moves_to_live
        rm -rf "${OB_STAGING}"
        exit 1
    fi
    if ! mv "${OB_STAGING}" "${INSTALL_DIR}"; then
        log_error "Upgrade failed mid-swap. Restoring previous install from ${OB_ROLLBACK}."
        _ob_undo_moves_to_rollback
        rm -rf "${OB_STAGING}"
        mv "${OB_ROLLBACK}" "${INSTALL_DIR}" \
            || log_error "CRITICAL: could not restore rollback directory ${OB_ROLLBACK} → ${INSTALL_DIR}. Manual intervention required."
        exit 1
    fi

    log_ok "Upgrade applied atomically. Rollback copy preserved at ${OB_ROLLBACK} until health probe confirms success."
else
    mkdir -p "${INSTALL_DIR}"
    tar xzf "${tmp_tar}" -C "${INSTALL_DIR}" --strip-components=1 2>/dev/null || {
        tar xzf "${tmp_tar}" -C "${INSTALL_DIR}"
    }
    rm -f "${tmp_tar}"
fi

log_ok "OpenBox downloaded to ${INSTALL_DIR}"

# --- Setup ---
chmod +x "${INSTALL_DIR}/openbox"
chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true

# Symlink CLI to PATH
if [[ -d /usr/local/bin ]]; then
    ln -sf "${INSTALL_DIR}/openbox" /usr/local/bin/openbox
elif [[ "${IS_NAS}" == true ]]; then
    local_bin="${HOME}/.local/bin"
    mkdir -p "${local_bin}" 2>/dev/null || true
    if [[ -d "${local_bin}" ]]; then
        ln -sf "${INSTALL_DIR}/openbox" "${local_bin}/openbox"
        log_info "CLI symlinked to ${local_bin}/openbox"
        if ! echo "${PATH}" | grep -q "${local_bin}"; then
            log_warn "Add ${local_bin} to your PATH: export PATH=\"${local_bin}:\${PATH}\""
        fi
    else
        log_info "Run OpenBox directly: ${INSTALL_DIR}/openbox"
    fi
fi

# Create required directories
mkdir -p "${INSTALL_DIR}/state"
mkdir -p "${INSTALL_DIR}/backups"

# Dashboard container runs as uid 1000 — make install dir writable
chown 1000:1000 "${INSTALL_DIR}" 2>/dev/null || true

# Store install metadata
{
    echo "INSTALL_DIR=${INSTALL_DIR}"
    echo "IS_NAS=${IS_NAS}"
    echo "NAS_TYPE=${NAS_TYPE}"
    echo "OB_PROFILE=${OB_PROFILE:-}"
    echo "OB_PROFILE_REASONS=${OB_PROFILE_REASONS:-}"
    echo "INSTALL_DATE=$(date -Iseconds 2>/dev/null || date)"
} > "${INSTALL_DIR}/state/install-meta.conf"

log_ok "OpenBox installed to ${INSTALL_DIR}"
echo ""

# --- Configure Firewall (VPS only) ---
if [[ "${IS_NAS}" == true ]]; then
    log_info "NAS mode: skipping firewall configuration."
    log_info "Configure port forwarding through your NAS or router admin panel."
else
    if command -v ufw &>/dev/null; then
        log_info "Configuring firewall (UFW)..."
        ufw allow 22/tcp comment "SSH" > /dev/null 2>&1
        ufw allow 80/tcp comment "HTTP" > /dev/null 2>&1
        ufw allow 443/tcp comment "HTTPS" > /dev/null 2>&1
        ufw allow 51820/udp comment "WireGuard VPN" > /dev/null 2>&1
        echo "y" | ufw enable > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        ufw allow 8443/tcp comment "OpenBox Dashboard" > /dev/null 2>&1
        ufw allow 51821/tcp comment "WireGuard UI" > /dev/null 2>&1

        log_info "Opening module ports in UFW (parsed from modules/*/docker-compose.yml)..."
        _mport_count=0
        while IFS= read -r _mport; do
            [[ -z "${_mport}" ]] && continue
            ufw allow "${_mport}/tcp" comment "OpenBox module port" > /dev/null 2>&1 && _mport_count=$((_mport_count + 1))
        done < <(
            for _compose in "${INSTALL_DIR}"/modules/*/docker-compose.yml; do
                [[ -f "${_compose}" ]] || continue
                grep -oE '"[0-9]+:[0-9]+([^"]*)?"' "${_compose}" 2>/dev/null | \
                    sed 's/"//g' | \
                    awk -F: '{ print $1 }' | \
                    grep -E '^[0-9]+$'
            done | sort -u
        )
        log_ok "Opened ${_mport_count} module ports in UFW"
        ufw reload > /dev/null 2>&1
        log_ok "Firewall configured: SSH (22), HTTP (80), HTTPS (443), Dashboard (8443), WireGuard (51820/udp, 51821/tcp), ${_mport_count} module ports"

        if [[ -f /etc/docker/daemon.json ]] && grep -q '"iptables"' /etc/docker/daemon.json; then
            log_info "Removing legacy daemon.json iptables=false..."
            sed -i \
                -e 's/[[:space:]]*"iptables"[[:space:]]*:[[:space:]]*false[[:space:]]*,//g' \
                -e 's/,[[:space:]]*"iptables"[[:space:]]*:[[:space:]]*false[[:space:]]*//g' \
                -e 's/[[:space:]]*"iptables"[[:space:]]*:[[:space:]]*false[[:space:]]*//g' \
                /etc/docker/daemon.json
            if grep -qE '^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$' /etc/docker/daemon.json; then
                rm /etc/docker/daemon.json
            fi
            systemctl restart docker 2>/dev/null || true
            log_ok "Docker iptables management restored — container egress works"
        fi

        if [[ -f /etc/default/ufw ]]; then
            log_info "Setting UFW forward policy to ACCEPT (container egress)..."
            if grep -qE '^[[:space:]]*DEFAULT_FORWARD_POLICY[[:space:]]*=' /etc/default/ufw; then
                sed -i -E 's|^[[:space:]]*DEFAULT_FORWARD_POLICY[[:space:]]*=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|' /etc/default/ufw
            else
                echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
            fi
            ufw reload > /dev/null 2>&1
            log_ok "UFW forward policy set to ACCEPT — containers can reach the internet"
        fi

        # Container egress verification
        if [[ "${OB_TEST_MODE:-0}" == "1" ]]; then
            log_info "[TEST_MODE] Skipping container egress verification."
        else
            log_info "Verifying container egress to license server..."
            if ! docker network inspect ob_proxy &>/dev/null; then
                docker network create --subnet=172.20.0.0/24 ob_proxy >/dev/null 2>&1 || true
            fi
            docker pull -q curlimages/curl:latest >/dev/null 2>&1 || true
            if timeout 60 docker run --rm --network ob_proxy curlimages/curl:latest \
                    -sS -o /dev/null -m 30 https://crushcodeworks.com 2>/dev/null; then
                log_ok "Container egress verified: ob_proxy can reach crushcodeworks.com"
            else
                log_warn "Container egress check failed — ob_proxy cannot reach crushcodeworks.com."
                log_warn "  This is fine if you only need free OpenBox. Optional Pro-tier license"
                log_warn "  activation won't work until container egress is restored, but every"
                log_warn "  bundled app (Jellyfin, Pi-hole, Vaultwarden, Nextcloud, etc.) runs"
                log_warn "  the same either way."
            fi
        fi

        # iptable_nat for WireGuard
        if [[ "${OB_TEST_MODE:-0}" != "1" ]]; then
            if ! lsmod | grep -q '^iptable_nat'; then
                log_info "Loading iptable_nat kernel module (needed by WireGuard)..."
                modprobe iptable_nat 2>/dev/null || log_warn "modprobe iptable_nat failed; wg-easy may not start"
            fi
            mkdir -p /etc/modules-load.d
            echo iptable_nat > /etc/modules-load.d/openbox-wg.conf
            log_ok "iptable_nat module persisted for boot (wg-easy support)"
        fi

        # SSH hardening
        if [[ -f /etc/ssh/sshd_config ]]; then
            log_info "Hardening SSH..."
            sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
            sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
            sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
            systemctl restart sshd 2>/dev/null || true
            log_ok "SSH: password auth disabled, root login key-only"
        else
            log_info "SSH: /etc/ssh/sshd_config not found — skipping SSH hardening"
        fi

        # fail2ban
        if [[ "${OB_TEST_MODE:-0}" != "1" ]]; then
            if ! command -v fail2ban-client &>/dev/null; then
                log_info "Installing fail2ban..."
                pkg_install fail2ban
            fi
            if command -v fail2ban-client &>/dev/null; then
                cat > /etc/fail2ban/jail.local << 'F2B'
[sshd]
enabled = true
port = ssh
maxretry = 5
bantime = 3600
findtime = 600
F2B
                systemctl enable fail2ban > /dev/null 2>&1
                systemctl restart fail2ban > /dev/null 2>&1
                log_ok "fail2ban: SSH brute-force protection enabled"
            fi
        fi
    else
        log_info "Installing UFW firewall..."
        pkg_install ufw
        if command -v ufw &>/dev/null; then
            ufw default deny incoming > /dev/null 2>&1
            ufw default allow outgoing > /dev/null 2>&1
            ufw allow 22/tcp comment "SSH" > /dev/null 2>&1
            ufw allow 80/tcp comment "HTTP" > /dev/null 2>&1
            ufw allow 443/tcp comment "HTTPS" > /dev/null 2>&1
            ufw allow 51820/udp comment "WireGuard VPN" > /dev/null 2>&1
            ufw allow 8443/tcp comment "OpenBox Dashboard" > /dev/null 2>&1
            echo "y" | ufw enable > /dev/null 2>&1
            log_ok "Firewall installed and configured"

            if [[ -f /etc/docker/daemon.json ]] && grep -q '"iptables"' /etc/docker/daemon.json; then
                sed -i \
                    -e 's/[[:space:]]*"iptables"[[:space:]]*:[[:space:]]*false[[:space:]]*,//g' \
                    -e 's/,[[:space:]]*"iptables"[[:space:]]*:[[:space:]]*false[[:space:]]*//g' \
                    -e 's/[[:space:]]*"iptables"[[:space:]]*:[[:space:]]*false[[:space:]]*//g' \
                    /etc/docker/daemon.json
                if grep -qE '^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$' /etc/docker/daemon.json; then
                    rm /etc/docker/daemon.json
                fi
                systemctl restart docker 2>/dev/null || true
                log_ok "Docker iptables management restored"
            fi

            if [[ -f /etc/default/ufw ]]; then
                if grep -qE '^[[:space:]]*DEFAULT_FORWARD_POLICY[[:space:]]*=' /etc/default/ufw; then
                    sed -i -E 's|^[[:space:]]*DEFAULT_FORWARD_POLICY[[:space:]]*=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|' /etc/default/ufw
                else
                    echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
                fi
                ufw reload > /dev/null 2>&1
                log_ok "UFW forward policy set to ACCEPT"
            fi
        else
            log_warn "Could not install UFW. Please configure your firewall manually."
        fi
    fi
fi

# --- Run Setup Wizard (interactive only) ---
if [[ -t 0 ]] && [[ -t 1 ]]; then
    log_info "Launching setup wizard..."
    echo ""
    OB_ROOT="${INSTALL_DIR}" IS_NAS="${IS_NAS}" NAS_TYPE="${NAS_TYPE}" bash "${INSTALL_DIR}/scripts/setup.sh"
else
    log_info "Non-interactive install detected (piped from curl). Skipping wizard."
    log_info "Bringing up core services so the dashboard is reachable..."
    mkdir -p "${INSTALL_DIR}/state"
    if [[ "${OB_UPGRADE_MODE}" != "true" ]] && [[ ! -f "${INSTALL_DIR}/state/modules.conf" ]]; then
        echo -e "core\ndashboard" > "${INSTALL_DIR}/state/modules.conf"
    fi

    gen_secret() {
        openssl rand -hex 32 2>/dev/null || echo "changeme-$(date +%s)-$RANDOM"
    }
    gen_password() {
        openssl rand -base64 24 2>/dev/null | tr -d '=+/' | head -c 24 || echo "changeme$(date +%s)"
    }

    if [[ "${OB_UPGRADE_MODE}" == "true" ]] && [[ -f "${INSTALL_DIR}/.env" ]]; then
        log_info "Keeping existing .env from previous install."
    else
        OB_BOOTSTRAP_TOKEN_VALUE="$(gen_secret | head -c 16)"

        {
            echo "# OpenBox configuration"
            echo "# Generated by non-interactive install on $(date -Iseconds 2>/dev/null || date)"
            echo ""
            echo "# --- Core paths + identity ---"
            echo "OB_ROOT=${INSTALL_DIR}"
            echo "OB_SESSION_SECRET=$(gen_secret)"
            echo "OB_BACKUP_KEY=$(gen_secret)"
            echo "OB_BOOTSTRAP_TOKEN=${OB_BOOTSTRAP_TOKEN_VALUE}"
            OB_HOST_IP_VALUE="$(hostname -I 2>/dev/null | awk '{print $1}')"
            echo "OB_HOST_IP=${OB_HOST_IP_VALUE:-127.0.0.1}"
            echo "OB_DOMAIN=${OB_HOST_IP_VALUE:-127.0.0.1}"
            echo "TZ=${TZ:-UTC}"
            ob_puid_val="${SUDO_UID:-1000}"
            ob_pgid_val="${SUDO_GID:-1000}"
            [[ "${ob_puid_val}" -lt 1 ]] && ob_puid_val=1000
            [[ "${ob_pgid_val}" -lt 1 ]] && ob_pgid_val=1000
            echo "PUID=${ob_puid_val}"
            echo "PGID=${ob_pgid_val}"
            unset ob_puid_val ob_pgid_val
            echo "OB_DATA_DIR=${OB_DATA_DIR_VALUE}"
            echo "MEDIA_ROOT=${OB_DATA_DIR_VALUE}/media"
            echo ""
            echo "# --- Network ports ---"
            if [[ -n "${HTTP_PORT:-}" && -n "${HTTPS_PORT:-}" ]]; then
                echo "HTTP_PORT=${HTTP_PORT}"
                echo "HTTPS_PORT=${HTTPS_PORT}"
            elif [[ "${NAS_TYPE}" == "ugreen" ]]; then
                echo "HTTP_PORT=8080"
                echo "HTTPS_PORT=8444"
            else
                echo "HTTP_PORT=80"
                echo "HTTPS_PORT=443"
            fi
            echo "PIHOLE_DNS_PORT=${PIHOLE_DNS_PORT:-53}"
            echo "PORTAINER_PORT=9000"
            echo "JELLYFIN_HW_ACCEL=auto"
            echo "MOONFIN_ENABLED=false"
            echo ""
            echo "# --- Auto-generated secrets (change via Settings page) ---"
            echo "PIHOLE_PASSWORD=$(gen_password)"
            echo "VAULTWARDEN_ADMIN_TOKEN=$(gen_secret)"
            echo "VAULTWARDEN_SIGNUPS=false"
            echo "VAULTWARDEN_DOMAIN=https://vault.openbox.local"
            echo "AUTHELIA_JWT_SECRET=$(gen_secret)"
            echo "AUTHELIA_SESSION_SECRET=$(gen_secret)"
            echo "AUTHELIA_STORAGE_ENCRYPTION_KEY=$(gen_secret)"
            echo "NEXTCLOUD_DB_PASSWORD=$(gen_password)"
            echo "NEXTCLOUD_DB_ROOT_PASSWORD=$(gen_password)"
            echo "IMMICH_DB_PASSWORD=$(gen_password)"
            echo "PAPERLESS_DB_PASSWORD=$(gen_password)"
            echo "PAPERLESS_SECRET_KEY=$(gen_secret)"
            echo "GITEA_DB_PASSWORD=$(gen_password)"
            echo "N8N_DB_PASSWORD=$(gen_password)"
            echo "N8N_ENCRYPTION_KEY=$(gen_secret)"
            echo "HOMARR_SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32 2>/dev/null || gen_secret)"
            echo "SPEEDTEST_APP_KEY=base64:$(openssl rand -base64 32 2>/dev/null | head -c 44 || gen_secret)"
            echo "BOOKSTACK_DB_PASSWORD=$(gen_password)"
            echo "BOOKSTACK_APP_KEY=base64:$(openssl rand -base64 32 2>/dev/null | head -c 44 || echo 'changeme-app-key-change-me-change-me-chngme')"
            echo "DUPLICATI_PASSWORD=$(gen_password)"
            echo "FRIGATE_RTSP_PASSWORD=$(gen_password)"
            echo "GRAFANA_ADMIN_PASSWORD=$(gen_password)"
            echo "PHOTOPRISM_ADMIN_PASSWORD=$(gen_password)"
            echo "GOTIFY_ADMIN_PW=$(gen_password)"
            echo "FILEBROWSER_ADMIN_PW=$(gen_password)"
            echo "WEBUI_SECRET_KEY=$(gen_secret)"
            echo "OLLAMA_DEFAULT_MODEL=llama3.2:3b"
            echo "PHOTOS_PATH=${OB_DATA_DIR_VALUE}/photos"
            echo "BOOKS_PATH=${OB_DATA_DIR_VALUE}/books"
            echo "MANGA_PATH=${OB_DATA_DIR_VALUE}/manga"
            echo "MATRIX_SERVER_NAME=matrix.openbox.local"
            echo ""
            echo "# --- VPN (strongly recommended for media stack) ---"
            echo "VPN_PROVIDER="
            echo "VPN_TYPE=wireguard"
            echo "VPN_USER="
            echo "VPN_PASSWORD="
            echo "WIREGUARD_PRIVATE_KEY="
            echo "WIREGUARD_ADDRESSES="
            echo "SERVER_COUNTRIES="
            echo "SERVER_CITIES="
            echo "SERVER_HOSTNAMES="
            echo ""
            echo "# --- Remote access (fill in to use tailscale module) ---"
            echo "TS_AUTHKEY="
            echo "WG_HOST=localhost"
            echo "WG_PASSWORD_HASH="
            echo ""
            echo "# --- Linkding admin ---"
            LINKDING_ADMIN_PW_VALUE="$(gen_password)"
            echo "LINKDING_ADMIN_USER=admin"
            echo "LINKDING_ADMIN_PASSWORD=${LINKDING_ADMIN_PW_VALUE}"
        } > "${INSTALL_DIR}/.env"

        chmod 600 "${INSTALL_DIR}/.env"

        if [[ -n "${LINKDING_ADMIN_PW_VALUE:-}" ]]; then
            mkdir -p "${INSTALL_DIR}/state"
            printf 'username: admin\npassword: %s\n' "${LINKDING_ADMIN_PW_VALUE}" > "${INSTALL_DIR}/state/linkding-admin-password.txt"
            chmod 600 "${INSTALL_DIR}/state/linkding-admin-password.txt"
            log_ok "Linkding admin password pre-seeded"
        fi

        PIHOLE_ADMIN_PW_VALUE=$(grep -E '^PIHOLE_PASSWORD=' "${INSTALL_DIR}/.env" | head -1 | cut -d= -f2-)
        if [[ -n "${PIHOLE_ADMIN_PW_VALUE:-}" ]]; then
            mkdir -p "${INSTALL_DIR}/state"
            printf 'username: admin\npassword: %s\nurl: http://%s:8053/admin/\n' \
                "${PIHOLE_ADMIN_PW_VALUE}" "${OB_HOST_IP_VALUE:-localhost}" \
                > "${INSTALL_DIR}/state/pihole-admin-password.txt"
            chmod 600 "${INSTALL_DIR}/state/pihole-admin-password.txt"
            log_ok "Pi-hole admin password pre-seeded"
        fi

        # Vaultwarden access guide
        if [[ -f "${INSTALL_DIR}/.env" ]]; then
            VW_ADMIN_TOKEN=$(grep -E '^VAULTWARDEN_ADMIN_TOKEN=' "${INSTALL_DIR}/.env" | head -1 | cut -d= -f2-)
            if [[ -n "${VW_ADMIN_TOKEN:-}" ]]; then
                cat > "${INSTALL_DIR}/state/vaultwarden-admin-password.txt" <<VWINFO
# Vaultwarden — three ways to access your vault
#
# 1. BROWSER EXTENSION (recommended): install Bitwarden extension → settings
#    → Server URL: http://${OB_HOST_IP_VALUE:-<NAS_IP>}:8222
#    Works over HTTP because the extension runs in a privileged context.
#
# 2. MOBILE APP: same — Bitwarden app → settings → self-hosted →
#    http://${OB_HOST_IP_VALUE:-<NAS_IP>}:8222
#
# 3. WEB VAULT: does NOT work over plain HTTP — Bitwarden uses
#    window.crypto.subtle which browsers only expose on HTTPS or localhost.
#    Set up an HTTPS proxy host in NPM (port 443/8444) pointing at
#    ob-vaultwarden:80 to use the web vault.
#
# ADMIN PANEL:
#    http://${OB_HOST_IP_VALUE:-<NAS_IP>}:8222/admin/
#    token: ${VW_ADMIN_TOKEN}
VWINFO
                chmod 600 "${INSTALL_DIR}/state/vaultwarden-admin-password.txt"
            fi
        fi
    fi  # end regenerate .env

    # Pre-create media data dirs
    mkdir -p "${OB_DATA_DIR_VALUE}/media/Movies" \
             "${OB_DATA_DIR_VALUE}/media/TV" \
             "${OB_DATA_DIR_VALUE}/media/Music" \
             "${OB_DATA_DIR_VALUE}/photos" \
             "${OB_DATA_DIR_VALUE}/books" \
             "${OB_DATA_DIR_VALUE}/manga" \
             "${OB_DATA_DIR_VALUE}/audiobooks" \
             "${OB_DATA_DIR_VALUE}/podcasts" 2>/dev/null || true

    _puid_val="${SUDO_UID:-1000}"
    _pgid_val="${SUDO_GID:-1000}"
    chown -R "${_puid_val}:${_pgid_val}" "${OB_DATA_DIR_VALUE}" 2>/dev/null || true

    # Render templates
    log_info "Rendering module templates..."
    render_template() {
        local src="$1" dest="$2"
        [[ -f "${src}" ]] || return
        mkdir -p "$(dirname "${dest}")"
        local content
        content=$(cat "${src}")
        while IFS='=' read -r key value; do
            [[ -z "${key}" || "${key}" =~ ^# ]] && continue
            content="${content//\{\{${key}\}\}/${value}}"
        done < "${INSTALL_DIR}/.env"
        echo "${content}" > "${dest}"
    }

    if [[ -f "${INSTALL_DIR}/templates/prometheus-config.yml.tmpl" ]]; then
        render_template \
            "${INSTALL_DIR}/templates/prometheus-config.yml.tmpl" \
            "${INSTALL_DIR}/modules/metrics/config/prometheus.yml"
    fi

    if [[ -f "${INSTALL_DIR}/templates/element-config.json.tmpl" ]]; then
        render_template \
            "${INSTALL_DIR}/templates/element-config.json.tmpl" \
            "${INSTALL_DIR}/modules/matrix/config/element/config.json"
    fi

    # Pi-hole privacy config
    mkdir -p "${INSTALL_DIR}/modules/pihole/config/dnsmasq"
    cat > "${INSTALL_DIR}/modules/pihole/config/dnsmasq/05-openbox-privacy.conf" << 'PIHOLE_PRIVACY'
# OpenBox Privacy: block NAS vendor telemetry domains.
address=/ugnas.com/0.0.0.0
address=/ug.link/0.0.0.0
address=/ugreen.cloud/0.0.0.0
address=/crashlytics.com/0.0.0.0
PIHOLE_PRIVACY
    log_ok "Pi-hole pre-configured with NAS telemetry blocklist"

    # Authelia config
    if [[ -f "${INSTALL_DIR}/templates/authelia-config.yml.tmpl" ]]; then
        mkdir -p "${INSTALL_DIR}/modules/authelia/config"
        render_template \
            "${INSTALL_DIR}/templates/authelia-config.yml.tmpl" \
            "${INSTALL_DIR}/modules/authelia/config/configuration.yml"
        if ! type gen_password >/dev/null 2>&1; then
            log_error "gen_password helper is not defined — this is an install.sh bug, please report."
            exit 1
        fi
        AUTHELIA_ADMIN_PW="$(gen_password)"
        if [[ -z "${AUTHELIA_ADMIN_PW}" ]]; then
            log_error "Authelia admin password generation returned empty. Aborting."
            exit 1
        fi
        if command -v argon2 &>/dev/null; then
            AUTHELIA_PW_HASH=$(echo -n "${AUTHELIA_ADMIN_PW}" | argon2 "$(openssl rand -base64 16)" -id -t 3 -m 16 -p 4 -l 32 -e 2>/dev/null)
        else
            AUTHELIA_PW_HASH='$argon2id$v=19$m=65536,t=3,p=4$BpLnfgDsc2WD8F2q$o/vzA4myCqZZ36bUGsDY//8mKUYNZZaR0t4MFFSs+iM'
            echo "${AUTHELIA_ADMIN_PW}" > "${INSTALL_DIR}/state/authelia-admin-password.txt"
            chmod 600 "${INSTALL_DIR}/state/authelia-admin-password.txt"
        fi
        cat > "${INSTALL_DIR}/modules/authelia/config/users_database.yml" << AUTHUSERS
---
users:
  admin:
    disabled: false
    displayname: 'Admin'
    password: '${AUTHELIA_PW_HASH}'
    email: admin@${OB_HOST_IP_VALUE:-localhost}
    groups:
      - admins
AUTHUSERS
    fi

    # Portainer password
    if [[ ! -f "${INSTALL_DIR}/modules/core/config/portainer-admin-password" ]]; then
        mkdir -p "${INSTALL_DIR}/modules/core/config"
        PORTAINER_ADMIN_PW="$(gen_password)"
        if [[ -z "${PORTAINER_ADMIN_PW}" ]]; then
            log_warn "Portainer admin password generation returned empty."
        else
            printf '%s' "${PORTAINER_ADMIN_PW}" > "${INSTALL_DIR}/modules/core/config/portainer-admin-password"
            chmod 600 "${INSTALL_DIR}/modules/core/config/portainer-admin-password"
            mkdir -p "${INSTALL_DIR}/state"
            printf 'username: admin\npassword: %s\n' "${PORTAINER_ADMIN_PW}" > "${INSTALL_DIR}/state/portainer-admin-password.txt"
            chmod 600 "${INSTALL_DIR}/state/portainer-admin-password.txt"
            log_ok "Portainer admin password pre-seeded"
        fi
    fi

    # Gotify password
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        GOTIFY_PW_LINE=$(grep '^GOTIFY_ADMIN_PW=' "${INSTALL_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
        if [[ -n "${GOTIFY_PW_LINE}" ]]; then
            mkdir -p "${INSTALL_DIR}/state"
            printf 'username: admin\npassword: %s\n' "${GOTIFY_PW_LINE}" > "${INSTALL_DIR}/state/gotify-admin-password.txt"
            chmod 600 "${INSTALL_DIR}/state/gotify-admin-password.txt"
            log_ok "Gotify admin password pre-seeded"
        fi
        FB_PW_LINE=$(grep '^FILEBROWSER_ADMIN_PW=' "${INSTALL_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
        if [[ -n "${FB_PW_LINE}" ]]; then
            printf 'username: admin\npassword: %s\n' "${FB_PW_LINE}" > "${INSTALL_DIR}/state/filebrowser-admin-password.txt"
            chmod 600 "${INSTALL_DIR}/state/filebrowser-admin-password.txt"
            log_ok "FileBrowser admin password pre-seeded"
        fi
    fi

    # qBittorrent password
    if [[ -f "${INSTALL_DIR}/state/qbittorrent-admin-password.txt" ]]; then
        QBIT_ADMIN_PW="$(grep -oE '^password:[[:space:]]+\S+' "${INSTALL_DIR}/state/qbittorrent-admin-password.txt" 2>/dev/null | head -n1 | awk '{print $2}')"
        if [[ -z "${QBIT_ADMIN_PW}" ]]; then
            QBIT_ADMIN_PW="$(head -n1 "${INSTALL_DIR}/state/qbittorrent-admin-password.txt" 2>/dev/null | tr -d '\r\n')"
        fi
    else
        QBIT_ADMIN_PW=""
    fi
    if [[ -z "${QBIT_ADMIN_PW}" ]]; then
        QBIT_ADMIN_PW="$(gen_password)"
    fi

    if [[ -n "${QBIT_ADMIN_PW}" ]]; then
        QBIT_PW_LINE=""
        if python3 -c "import hashlib,secrets,base64" >/dev/null 2>&1; then
            QBIT_PW_LINE=$(OB_QBIT_PW="${QBIT_ADMIN_PW}" python3 -c "
import os, hashlib, secrets, base64
pw = os.environ['OB_QBIT_PW'].encode()
salt = secrets.token_bytes(16)
h = hashlib.pbkdf2_hmac('sha512', pw, salt, 100000, 64)
print('@ByteArray(' + base64.b64encode(salt).decode() + ':' + base64.b64encode(h).decode() + ')')" 2>/dev/null || true)
        fi
        if [[ -n "${QBIT_PW_LINE}" ]]; then
            mkdir -p "${INSTALL_DIR}/state"
            printf 'username: admin\npassword: %s\n' "${QBIT_ADMIN_PW}" > "${INSTALL_DIR}/state/qbittorrent-admin-password.txt"
            chmod 600 "${INSTALL_DIR}/state/qbittorrent-admin-password.txt"

            mkdir -p "${INSTALL_DIR}/modules/media/config/qbittorrent/custom-cont-init.d"
            cat > "${INSTALL_DIR}/modules/media/config/qbittorrent/custom-cont-init.d/00-set-admin-password.sh" <<'QBIT_INIT'
#!/bin/sh
CONF="/config/qBittorrent/qBittorrent.conf"
HASH_LINE='__OB_QBIT_HASH__'

for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -d /config/qBittorrent ] && break
    sleep 1
done
mkdir -p /config/qBittorrent

if [ -f "$CONF" ] && grep -q '^WebUI\\Password_PBKDF2=' "$CONF"; then
    if grep -q '^WebUI\\Password_PBKDF2="@ByteArray' "$CONF"; then
        sed -i 's|^WebUI\\Password_PBKDF2=.*|WebUI\\Password_PBKDF2='"$HASH_LINE"'|' "$CONF"
    else
        echo "[openbox-qbit-init] Password already set, skipping injection."
    fi
else
    : # Falls through
fi
SKIP_BUILD_CONF="${SKIP_BUILD_CONF:-}"
if [ -f "$CONF" ] && grep -q '^WebUI\\Password_PBKDF2=' "$CONF"; then
    SKIP_BUILD_CONF=1
fi

if [ -z "$SKIP_BUILD_CONF" ]; then
if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<EOF
[Preferences]
WebUI\Username=admin
WebUI\Password_PBKDF2=$HASH_LINE
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
EOF
elif ! grep -q '^\[Preferences\]' "$CONF"; then
    printf '\n[Preferences]\nWebUI\\Username=admin\nWebUI\\Password_PBKDF2=%s\nWebUI\\HostHeaderValidation=false\nWebUI\\CSRFProtection=false\n' "$HASH_LINE" >> "$CONF"
else
    sed -i "/^\\[Preferences\\]\$/a WebUI\\\\Username=admin\\nWebUI\\\\Password_PBKDF2=$HASH_LINE\\nWebUI\\\\HostHeaderValidation=false\\nWebUI\\\\CSRFProtection=false" "$CONF"
fi
fi

if ! grep -F 'HostHeaderValidation=' "$CONF" >/dev/null 2>&1; then
    if grep -q '^\[Preferences\]' "$CONF"; then
        awk '/^\[Preferences\]$/{print; print "WebUI\\HostHeaderValidation=false"; next} 1' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    else
        printf '\n[Preferences]\nWebUI\\HostHeaderValidation=false\n' >> "$CONF"
    fi
fi
if ! grep -F 'CSRFProtection=' "$CONF" >/dev/null 2>&1; then
    if grep -q '^\[Preferences\]' "$CONF"; then
        awk '/^\[Preferences\]$/{print; print "WebUI\\CSRFProtection=false"; next} 1' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    else
        printf '\n[Preferences]\nWebUI\\CSRFProtection=false\n' >> "$CONF"
    fi
fi

chown $(stat -c '%u:%g' /config/qBittorrent 2>/dev/null || echo 1000:1000) "$CONF" 2>/dev/null || true
chmod 600 "$CONF" 2>/dev/null || true
echo "[openbox-qbit-init] Injected admin password + LAN-access settings into $CONF"
QBIT_INIT
            sed -i "s|__OB_QBIT_HASH__|${QBIT_PW_LINE}|" "${INSTALL_DIR}/modules/media/config/qbittorrent/custom-cont-init.d/00-set-admin-password.sh"
            chmod 755 "${INSTALL_DIR}/modules/media/config/qbittorrent/custom-cont-init.d/00-set-admin-password.sh"
            chown -R 1000:1000 "${INSTALL_DIR}/modules/media/config/qbittorrent" 2>/dev/null || true
            chown -R 0:0 "${INSTALL_DIR}/modules/media/config/qbittorrent/custom-cont-init.d" 2>/dev/null || true
            log_ok "qBittorrent admin password pre-seeded"

            QBIT_CONF_HOST="${INSTALL_DIR}/modules/media/config/qbittorrent/qBittorrent/qBittorrent.conf"
            if [[ -f "${QBIT_CONF_HOST}" ]] && grep -q '^WebUI\\Password_PBKDF2="@ByteArray' "${QBIT_CONF_HOST}"; then
                sed -i 's|^WebUI\\Password_PBKDF2=.*|WebUI\\Password_PBKDF2='"${QBIT_PW_LINE}"'|' "${QBIT_CONF_HOST}"
                log_ok "qBittorrent: rewrote broken quoted @ByteArray hash in existing conf to unquoted form."
                if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ob-qbittorrent$'; then
                    docker restart ob-qbittorrent >/dev/null 2>&1 || true
                    log_ok "qBittorrent: restarted container so it re-reads the fixed conf."
                fi
            fi
        fi
    fi

    # Actual Budget TLS cert
    if [[ ! -f "${INSTALL_DIR}/modules/budget/config/certs/cert.pem" ]]; then
        mkdir -p "${INSTALL_DIR}/modules/budget/config/certs"
        _budget_san="DNS:localhost,IP:127.0.0.1"
        if [[ -n "${OB_HOST_IP_VALUE:-}" ]]; then
            _budget_san="${_budget_san},IP:${OB_HOST_IP_VALUE}"
        fi
        if openssl req -x509 -newkey rsa:2048 \
                -keyout "${INSTALL_DIR}/modules/budget/config/certs/key.pem" \
                -out "${INSTALL_DIR}/modules/budget/config/certs/cert.pem" \
                -sha256 -days 3650 -nodes \
                -subj "/CN=openbox-actual" \
                -addext "subjectAltName=${_budget_san}" \
                >/dev/null 2>&1; then
            _cert_puid=$(grep '^PUID=' "${INSTALL_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2)
            _cert_pgid=$(grep '^PGID=' "${INSTALL_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2)
            chmod 600 "${INSTALL_DIR}/modules/budget/config/certs/key.pem"
            chmod 644 "${INSTALL_DIR}/modules/budget/config/certs/cert.pem"
            chown "${_cert_puid:-1000}:${_cert_pgid:-1000}" \
                "${INSTALL_DIR}/modules/budget/config/certs/key.pem" \
                "${INSTALL_DIR}/modules/budget/config/certs/cert.pem" 2>/dev/null || true
            log_ok "Actual Budget TLS cert generated (self-signed, 10-year)"
        else
            log_warn "openssl not available — skipping Actual Budget TLS cert."
        fi
    fi

    # Fix ownership
    _puid=$(grep '^PUID=' "${INSTALL_DIR}/.env" | tail -1 | cut -d= -f2)
    _pgid=$(grep '^PGID=' "${INSTALL_DIR}/.env" | tail -1 | cut -d= -f2)
    mkdir -p "${INSTALL_DIR}/backups"
    chown -R "${_puid:-1000}:${_pgid:-1000}" \
        "${INSTALL_DIR}/.env" \
        "${INSTALL_DIR}/state" \
        "${INSTALL_DIR}/backups" \
        "${INSTALL_DIR}/modules" 2>/dev/null || true

    # Bring up core services
    cd "${INSTALL_DIR}"
    if [[ "${OB_TEST_MODE:-0}" == "1" ]] || [[ "${OB_SKIP_UP:-0}" == "1" ]]; then
        log_info "[TEST_MODE/SKIP_UP] Skipping 'openbox up' — install validated."
    elif [[ -x "${INSTALL_DIR}/openbox" ]]; then
        ob_up_log=$(mktemp)
        if ! OB_SKIP_LOCK=1 "${INSTALL_DIR}/openbox" up >"${ob_up_log}" 2>&1; then
            echo ""
            echo -e "${RED}[FAILURE]${NC} OpenBox installed, but Docker couldn't start the core services."
            echo -e "${RED}[FAILURE]${NC} Last 20 lines of the openbox up log:"
            tail -20 "${ob_up_log}"
            echo ""
            echo -e "${RED}[FAILURE]${NC} Next steps:"
            echo -e "${RED}[FAILURE]${NC}   1. Run: ${INSTALL_DIR}/openbox doctor"
            echo -e "${RED}[FAILURE]${NC}   2. Fix what it reports, then run: ${INSTALL_DIR}/openbox up"
            rm -f "${ob_up_log}"
            exit 1
        fi
        rm -f "${ob_up_log}"
    fi
    echo ""
    log_ok "OpenBox installed to ${INSTALL_DIR}"
    echo ""

    if [[ "${OB_UPGRADE_MODE}" != "true" ]]; then
        {
            echo "============================================================"
            echo "  ONE-TIME BOOTSTRAP TOKEN — required for first login"
            echo "============================================================"
            echo ""
            echo "    ${OB_BOOTSTRAP_TOKEN_VALUE}"
            echo ""
            echo "  Save this token. You will be asked for it the first time"
            echo "  you open the dashboard to set your admin password. It is"
            echo "  then burned and cannot be reused."
            echo ""
            echo "  Lost it? Run:  sudo ${INSTALL_DIR}/openbox bootstrap-token"
            echo ""
            echo "============================================================"
            echo ""
        } >&2
        log_info "Next steps:"
        echo "  1. Open the dashboard: http://$(hostname -I 2>/dev/null | awk '{print $1}'):8443"
        echo "  2. Paste the bootstrap token above and pick an admin password"
        echo "  3. Follow the setup wizard in your browser"
        echo ""
        log_warn "STRONGLY RECOMMENDED: Enable VPN before downloading media."
        log_warn "  A VPN protects your privacy when using P2P protocols."
        log_warn "  Configure it in: Dashboard → Settings → VPN"
        log_warn "  This is optional — media stack works without VPN, but at your own risk."
        echo ""
        {
            _ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            : "${_ip:=127.0.0.1}"
            echo "============================================================"
            echo "  INSTALL COMPLETE — your last-screen quick-reference"
            echo "============================================================"
            echo ""
            echo "  Dashboard:  http://${_ip}:8443"
            echo ""
            echo "  Bootstrap token (paste this on first login):"
            echo ""
            echo "    ${OB_BOOTSTRAP_TOKEN_VALUE}"
            echo ""
            echo "  Lost it later?  sudo ${INSTALL_DIR}/openbox bootstrap-token"
            echo ""
            echo "============================================================"
            echo ""
        } >&2
    else
        log_info "Upgrade complete. Dashboard preserved its previous login."
        echo "  Dashboard: http://$(hostname -I 2>/dev/null | awk '{print $1}'):8443"
        echo ""
    fi
fi
# ===END===
