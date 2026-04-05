#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://github.com/devcontainers/features/blob/main/LICENSE for license information.
#-------------------------------------------------------------------------------------------------------------------------
#
# Docs: https://github.com/devcontainers/features/tree/main/src/node
# Maintainer: The Dev Container spec maintainers

export NODE_VERSION="${VERSION:-"lts"}"
export PNPM_VERSION="${PNPMVERSION:-"latest"}"
export NVM_VERSION="${NVMVERSION:-"latest"}"
export NVM_DIR="${NVMINSTALLPATH:-"/usr/local/share/nvm"}"
INSTALL_TOOLS_FOR_NODE_GYP="${NODEGYPDEPENDENCIES:-true}"
export INSTALL_YARN_USING_APT="${INSTALLYARNUSINGAPT:-false}" # only concerns Debian-based systems

# Comma-separated list of node versions to be installed (with nvm)
# alongside NODE_VERSION, but not set as default.
ADDITIONAL_VERSIONS="${ADDITIONALVERSIONS:-""}"

USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"
UPDATE_RC="${UPDATE_RC:-"true"}"

set -e

if [[ "$(id -u)" -ne 0 ]]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Bring in ID, ID_LIKE, VERSION_ID, VERSION_CODENAME
source /etc/os-release
# Get an adjusted ID independent of distro variants
MAJOR_VERSION_ID="${VERSION_ID%%.*}"
if [[ $ID == debian || ${ID_LIKE-} == debian ]]; then
    ADJUSTED_ID="debian"
elif [[ $ID == rhel || $ID == fedora || $ID == mariner || ${ID_LIKE-} == *rhel* || ${ID_LIKE-} == *fedora* || ${ID_LIKE-} == *mariner* ]]; then
    ADJUSTED_ID="rhel"
    if [[ $ID == rhel || $ID == *alma* || $ID == *rocky* ]]; then
        VERSION_CODENAME="rhel${MAJOR_VERSION_ID}"
    else
        VERSION_CODENAME="${ID}${MAJOR_VERSION_ID}"
    fi
else
    echo "Linux distro ${ID} not supported."
    exit 1
fi

if [[ $ADJUSTED_ID == rhel && ${VERSION_CODENAME-} == centos7 ]]; then
    # As of 1 July 2024, mirrorlist.centos.org no longer exists.
    # Update the repo files to reference vault.centos.org.
    sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/*.repo
    sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/*.repo
    sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/*.repo
fi

# Setup INSTALL_CMD & PKG_MGR_CMD
if command -v apt-get &>/dev/null; then
    PKG_MGR_CMD=apt-get
    INSTALL_CMD="${PKG_MGR_CMD} -y install --no-install-recommends"
elif command -v microdnf &>/dev/null; then
    PKG_MGR_CMD=microdnf
    INSTALL_CMD="${PKG_MGR_CMD} -y install --refresh --best --nodocs --noplugins --setopt=install_weak_deps=0"
elif command -v dnf &>/dev/null; then
    PKG_MGR_CMD=dnf
    INSTALL_CMD="${PKG_MGR_CMD} -y install"
else
    PKG_MGR_CMD=yum
    INSTALL_CMD="${PKG_MGR_CMD} -y install"
fi

# Clean up
clean_up() {
    case $ADJUSTED_ID in
    debian)
        rm -rf /var/lib/apt/lists/*
        ;;
    rhel)
        rm -rf /var/cache/dnf/* /var/cache/yum/*
        rm -f /etc/yum.repos.d/yarn.repo
        ;;
    esac
}
clean_up

# Ensure that login shells get the correct path if the user updated the PATH using ENV.
rm -f /etc/profile.d/00-restore-env.sh
echo "export PATH=${PATH//$(sh -lc 'echo $PATH')/\$PATH}" >/etc/profile.d/00-restore-env.sh
chmod +x /etc/profile.d/00-restore-env.sh

updaterc() {
    local system_bashrc
    local system_zshrc
    if [[ $UPDATE_RC == true ]]; then
        case $ADJUSTED_ID in
        debian)
            system_bashrc=/etc/bash.bashrc
            system_zshrc=/etc/zsh/zshrc
            ;;
        rhel)
            system_bashrc=/etc/bashrc
            system_zshrc=/etc/zshrc
            ;;
        esac
        echo "Updating ${system_bashrc} and ${system_zshrc}..."
        if [[ "$(cat ${system_bashrc})" != *"$1"* ]]; then
            echo -e "$1" >>"${system_bashrc}"
        fi
        if [[ -f "${system_zshrc}" ]] && [[ "$(cat ${system_zshrc})" != *"$1"* ]]; then
            echo -e "$1" >>"${system_zshrc}"
        fi
    fi
}

pkg_mgr_update() {
    case $ADJUSTED_ID in
    debian)
        if [[ "$(find /var/lib/apt/lists/* 2>/dev/null | wc -l)" == "0" ]]; then
            echo "Running apt-get update..."
            ${PKG_MGR_CMD} update -y
        fi
        ;;
    rhel)
        if [[ $PKG_MGR_CMD == microdnf ]]; then
            if [[ -z "$(find /var/cache/yum/ -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
                echo "Running ${PKG_MGR_CMD} makecache ..."
                ${PKG_MGR_CMD} makecache
            fi
        else
            if [[ -z "$(find /var/cache/${PKG_MGR_CMD}/ -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
                echo "Running ${PKG_MGR_CMD} check-update ..."
                set +e
                stderr_messages=$(${PKG_MGR_CMD} -q check-update 2>&1)
                rc=$?
                # centos 7 sometimes returns a status of 100 when it appears to work.
                if ((rc != 0 && rc != 100)); then
                    echo "(Error) ${PKG_MGR_CMD} check-update produced the following error message(s):"
                    echo "${stderr_messages}"
                    exit 1
                fi
                set -e
            fi
        fi
        ;;
    esac
}

# Checks if packages are installed and installs them if not
check_packages() {
    case $ADJUSTED_ID in
    debian)
        if ! dpkg -s "$@" &>/dev/null; then
            pkg_mgr_update
            ${INSTALL_CMD} "$@"
        fi
        ;;
    rhel)
        if ! rpm -q "$@" &>/dev/null; then
            pkg_mgr_update
            ${INSTALL_CMD} "$@"
        fi
        ;;
    esac
}

# Figure out correct version of a three part version number is not passed
find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    [[ $requested_version == none ]] && return

    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}

    local escaped_separator=${separator//./\\.}
    local last_part_regex
    if [[ $last_part_optional == true ]]; then
        last_part_regex="(${escaped_separator}[0-9]+)?"
    else
        last_part_regex="${escaped_separator}[0-9]+"
    fi

    local regex="${prefix}\\K[0-9]+${escaped_separator}[0-9]+${last_part_regex}$"
    local version_list
    version_list="$(git ls-remote --tags "${repository}" | grep -oP "${regex}" | tr -d ' ' | tr "${separator}" "." | sort -rV)"

    if [[ $requested_version =~ ^(latest|current|lts)$ ]]; then
        declare -g "${variable_name}"="${version_list%%$'\n'*}"
    elif [[ $requested_version != *.*.* ]]; then
        local matched_version
        matched_version="$(grep -E -m 1 "^${requested_version//./\\.}([\\.[:space:]]|$)" <<<"${version_list}" || true)"
        declare -g "${variable_name}"="${matched_version}"
    else
        declare -g "${variable_name}"="${requested_version}"
    fi

    if [[ -z "${!variable_name}" ]] || ! grep -Fqx -- "${!variable_name}" <<<"${version_list}"; then
        printf "Invalid %s value: %s\nValid values:\n%s\n" "${variable_name}" "${requested_version}" "${version_list}" >&2
        exit 1
    fi

    printf "%s=%s\n" "${variable_name}" "${!variable_name}"
}

# Helper: Run a command as a user with NVM environment
# Usage: run_as_user_with_nvm "nvm install 18"
run_as_user_with_nvm() {
    local cmd="$1"
    su "${USERNAME}" -c "umask 0002 && source '${NVM_DIR}/nvm.sh' && ${cmd}"
}

# Helper: Run a command as a user with umask
# Usage: run_as_user "some command"
run_as_user() {
    local cmd="$1"
    su "${USERNAME}" -c "umask 0002 && ${cmd}"
}

# Helper: Check if command exists in current shell with NVM
# Usage: check_cmd_with_nvm "yarn"
check_cmd_with_nvm() {
    local cmd_name="$1"
    bash -c "source '${NVM_DIR}/nvm.sh' && command -v '${cmd_name}' &>/dev/null"
}

# Helper: Check if current OS is unsupported for Node >= 18
is_unsupported_os_for_node18() {
    [[ "$VERSION_CODENAME" == *"bionic"* ]] ||
        [[ "${ADJUSTED_ID}${MAJOR_VERSION_ID}" == "rhel7" ]]
}

# Helper: Get major version from version string
# Usage: get_major_version "18.5.0"
get_major_version() {
    echo "${1%%.*}"
}

# Helper: Check if Node version is incompatible with this OS
requires_node18_or_higher() {
    local node_ver="$1"
    [[ "$node_ver" == "lts" || "$node_ver" == "latest" || $(get_major_version "$node_ver") -ge 18 ]]
}

# Helper: Determine the appropriate non-root user
determine_username() {
    # If automatic detection is requested
    if [[ $USERNAME == auto || $USERNAME == automatic ]]; then
        USERNAME=""
        local POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
        for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
            if id -u "${CURRENT_USER}" &>/dev/null; then
                USERNAME=${CURRENT_USER}
                return 0
            fi
        done
        # No suitable user found, fallback to root
        USERNAME=root
    # If explicitly set to "none" or user doesn't exist
    elif [[ $USERNAME == "none" ]] || ! id -u "$USERNAME" &>/dev/null; then
        USERNAME=root
    fi
}

install_yarn() {
    local node_version=${1:-node}

    # Debian APT-based installation
    if [[ $ADJUSTED_ID == debian && $INSTALL_YARN_USING_APT == true ]]; then
        if command -v yarn &>/dev/null; then
            echo "Yarn is already installed."
            return 0
        fi
        # Import key safely (new method rather than deprecated apt-key approach) and install
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor --yes -o /etc/apt/keyrings/yarn-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/yarn-archive-keyring.gpg] https://dl.yarnpkg.com/debian/ stable main" >/etc/apt/sources.list.d/yarn.list
        apt-get update
        apt-get -y install --no-install-recommends yarn
        return 0
    fi

    # Non-APT systems: prefer corepack, fallback to npm
    if check_cmd_with_nvm "yarn" &&
        bash -c "source '${NVM_DIR}/nvm.sh' && nvm use ${node_version} && command -v yarn &>/dev/null"; then
        echo "Yarn already installed."
        return 0
    fi

    # Try enabling corepack
    if bash -c "source '${NVM_DIR}/nvm.sh' && nvm use ${node_version} && command -v corepack &>/dev/null"; then
        run_as_user_with_nvm "nvm use ${node_version} && corepack enable"
    fi

    # Final check: if yarn still not available, use npm
    if ! bash -c "source '${NVM_DIR}/nvm.sh' && nvm use ${node_version} && command -v yarn &>/dev/null"; then
        # Yum/DNF want to install nodejs dependencies, we'll use NPM to install yarn
        run_as_user_with_nvm "nvm use ${node_version} && npm install --global yarn"
    fi
}

# Mariner does not have awk installed by default, this can cause
# problems if the username is auto* and later when we try to install
# node via npm.
if ! command -v awk &>/dev/null; then
    check_packages awk
fi

# Determine the appropriate non-root user
determine_username

# Ensure apt is in non-interactive to avoid prompts
export DEBIAN_FRONTEND=noninteractive

if is_unsupported_os_for_node18 && requires_node18_or_higher "$NODE_VERSION"; then
    echo "(!) Unsupported distribution version '${VERSION_CODENAME}' for Node >= 18. Details: https://github.com/nodejs/node/issues/42351#issuecomment-1068424442"
    exit 1
fi

# Install dependencies
case ${ADJUSTED_ID} in
debian)
    check_packages apt-transport-https curl ca-certificates tar gnupg2 dirmngr
    ;;
rhel)
    check_packages ca-certificates tar gnupg2 which findutils util-linux tar
    # minimal RHEL installs may not include curl, or includes curl-minimal instead.
    # Install curl if the "curl" command is not present.
    if ! command -v curl &>/dev/null; then
        check_packages curl
    fi
    ;;
esac

if ! command -v git &>/dev/null; then
    check_packages git
fi

# Adjust node version if required
if [[ $NODE_VERSION == none ]]; then
    export NODE_VERSION=
elif [[ $NODE_VERSION == lts ]]; then
    export NODE_VERSION="lts/*"
elif [[ $NODE_VERSION == latest ]]; then
    export NODE_VERSION="node"
fi

find_version_from_git_tags NVM_VERSION "https://github.com/nvm-sh/nvm"

# Install snippet that we will run as the user
nvm_install_snippet="$(
    cat <<EOF
set -e
umask 0002
# Do not update profile - we'll do this manually
export PROFILE=/dev/null
install_nvm_from_tag() {
    local tag="\$1"
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/\${tag}/install.sh" | bash
}

if ! install_nvm_from_tag "v${NVM_VERSION}"; then
    PREV_NVM_VERSION=$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    install_nvm_from_tag "\${PREV_NVM_VERSION}"
    NVM_VERSION="\${PREV_NVM_VERSION#v}"
fi
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
if [[ $NODE_VERSION ]]; then
    nvm alias default "${NODE_VERSION}"
fi
EOF
)"

# Snippet that should be added into rc / profiles
nvm_rc_snippet="$(
    cat <<EOF
export NVM_DIR="${NVM_DIR}"
for nvm_init_script in "\$NVM_DIR/nvm.sh" "\$NVM_DIR/bash_completion"; do
    [[ -s "\${nvm_init_script}" ]] && source "\${nvm_init_script}"
done
EOF
)"

# Create a symlink to the installed version for use in Dockerfile PATH statements
export NVM_SYMLINK_CURRENT=true

# Create nvm group to the user's UID or GID to change while still allowing access to nvm
if ! getent group nvm >/dev/null; then
    groupadd -r nvm
fi
usermod -a -G nvm "${USERNAME}"

# Install nvm (which also installs NODE_VERSION), otherwise
# use nvm to install the specified node version. Always use
# umask 0002 so that everything is u+rw,g+rw for both owner and group
umask 0002
if [[ ! -d $NVM_DIR ]]; then
    # Create nvm dir, and set sticky bit
    mkdir -p "${NVM_DIR}"
    chown "${USERNAME}:nvm" "${NVM_DIR}"
    chmod g+rws "${NVM_DIR}"
    su "${USERNAME}" -c "${nvm_install_snippet}" 2>&1
    # Update rc files
    if [[ $UPDATE_RC == true ]]; then
        updaterc "${nvm_rc_snippet}"
    fi
else
    echo "NVM already installed."
    if [[ $NODE_VERSION ]]; then
        run_as_user_with_nvm "nvm install '${NODE_VERSION}' && nvm alias default '${NODE_VERSION}'"
    fi
fi

# Possibly install yarn (puts yarn in per-Node install on RHEL, uses system yarn on Debian)
if [[ $NODE_VERSION && $NODE_VERSION != none ]]; then
    install_yarn
fi

# Additional node versions to be installed but not be set as
# default we can assume the nvm is the group owner of the nvm
# directory and the sticky bit on directories so any installed
# files will have the correct ownership (nvm)
if [[ $ADDITIONAL_VERSIONS ]]; then
    IFS="," read -r -a additional_versions <<<"$ADDITIONAL_VERSIONS"
    for ver in "${additional_versions[@]}"; do
        run_as_user_with_nvm "nvm install '${ver}'"
        # possibly install yarn (puts yarn in per-Node install on RHEL, uses system yarn on Debian)
        install_yarn "${ver}"
    done

    # Ensure $NODE_VERSION is on the $PATH
    if [[ $NODE_VERSION ]]; then
        run_as_user_with_nvm "nvm use default"
    fi
fi

# Install pnpm
if [[ $PNPM_VERSION && $PNPM_VERSION == none ]]; then
    echo "Ignoring installation of PNPM"
else
    if bash -c "source '${NVM_DIR}/nvm.sh' && command -v npm &>/dev/null"; then
        (
            source "${NVM_DIR}/nvm.sh"
            [[ "$http_proxy" ]] && npm set proxy="$http_proxy"
            [[ "$https_proxy" ]] && npm set https-proxy="$https_proxy"
            [[ "$no_proxy" ]] && npm set noproxy="$no_proxy"
            npm install -g pnpm@"$PNPM_VERSION" --force
        )
    else
        echo "Skip installing pnpm because npm is missing"
    fi
fi

# If enabled, verify "python3", "make", "gcc", "g++" commands are available so node-gyp works - https://github.com/nodejs/node-gyp
if [[ $INSTALL_TOOLS_FOR_NODE_GYP == true ]]; then
    echo "Verifying node-gyp OS requirements..."
    to_install=()
    if ! command -v make &>/dev/null; then
        to_install+=("make")
    fi
    if ! command -v gcc &>/dev/null; then
        to_install+=("gcc")
    fi
    if ! command -v g++ &>/dev/null; then
        if [[ $ADJUSTED_ID == "debian" ]]; then
            to_install+=("g++")
        elif [[ $ADJUSTED_ID == "rhel" ]]; then
            to_install+=("gcc-c++")
        fi
    fi
    if ! command -v python3 &>/dev/null; then
        if [[ $ADJUSTED_ID == "debian" ]]; then
            to_install+=("python3-minimal")
        elif [[ $ADJUSTED_ID == "rhel" ]]; then
            to_install+=("python3")
        fi
    fi
    if ((${#to_install[@]})); then
        pkg_mgr_update
        check_packages "${to_install[@]}"
    fi
fi

# Clean up
run_as_user_with_nvm "nvm clear-cache"
clean_up

# Ensure privs are correct for installed node versions. Unfortunately the
# way nvm installs node versions pulls privs from the tar which does not
# have group write set. We need this when the gid/uid is updated.
mkdir -p "${NVM_DIR}/versions"
chmod -R g+rw "${NVM_DIR}/versions"

echo "Done!"
