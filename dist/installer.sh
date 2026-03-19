#!/bin/bash
#
# Install Game Server
#
# Please ensure to run this script as root (or at least with sudo)
#
# @LICENSE AGPLv3
# @AUTHOR  Charlie Powell <cdp1337@bitsnbytes.dev>
# @CATEGORY Game Server
# @TRMM-TIMEOUT 600
# @WARLOCK-TITLE Valheim
# @WARLOCK-IMAGE media/valheim-1920x1080.webp
# @WARLOCK-ICON media/valheim-128x128.webp
# @WARLOCK-THUMBNAIL media/valheim-640x354.webp
#
# Supports:
#   Debian 12, 13
#   Ubuntu 24.04
#
# Requirements:
#   None
#
# TRMM Custom Fields:
#   None
#
# Syntax:
#   --uninstall  - Perform an uninstallation
#   --dir=<path> - Use a custom installation directory instead of the default (optional)
#   --skip-firewall  - Do not install or configure a system firewall
#   --non-interactive  - Run the installer in non-interactive mode (useful for scripted installs)
#   --branch=<str> - Use a specific branch of the management script repository DEFAULT=main
#
# Changelog:
#   20251103 - New installer

############################################
## Parameter Configuration
############################################

# Name of the game (used to create the directory)
INSTALLER_VERSION="v20251204"
GAME="Valheim"
GAME_DESC="Valheim Dedicated Server"
REPO="BitsNBytes25/Valheim-Installer"
WARLOCK_GUID="33201d07-4d80-c271-28d5-82548dde0a67"
STEAM_ID="896660"
GAME_USER="steam"
GAME_DIR="/home/${GAME_USER}/${GAME}"
GAME_SERVICE="valheim-server"
BEPINEX_URL="https://thunderstore.io/package/download/denikson/BepInExPack_Valheim/5.4.2333/"


function usage() {
  cat >&2 <<EOD
Usage: $0 [options]

Options:
    --uninstall  - Perform an uninstallation
    --dir=<path> - Use a custom installation directory instead of the default (optional)
    --skip-firewall  - Do not install or configure a system firewall
    --non-interactive  - Run the installer in non-interactive mode (useful for scripted installs)
    --branch=<str> - Use a specific branch of the management script repository DEFAULT=main

Please ensure to run this script as root (or at least with sudo)

@LICENSE AGPLv3
EOD
  exit 1
}

# Parse arguments
MODE_UNINSTALL=0
OVERRIDE_DIR=""
SKIP_FIREWALL=0
NONINTERACTIVE=0
BRANCH="main"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--uninstall) MODE_UNINSTALL=1;;
		--dir=*|--dir)
			[ "$1" == "--dir" ] && shift 1 && OVERRIDE_DIR="$1" || OVERRIDE_DIR="${1#*=}"
			[ "${OVERRIDE_DIR:0:1}" == "'" ] && [ "${OVERRIDE_DIR:0-1}" == "'" ] && OVERRIDE_DIR="${OVERRIDE_DIR:1:-1}"
			[ "${OVERRIDE_DIR:0:1}" == '"' ] && [ "${OVERRIDE_DIR:0-1}" == '"' ] && OVERRIDE_DIR="${OVERRIDE_DIR:1:-1}"
			;;
		--skip-firewall) SKIP_FIREWALL=1;;
		--non-interactive) NONINTERACTIVE=1;;
		--branch=*|--branch)
			[ "$1" == "--branch" ] && shift 1 && BRANCH="$1" || BRANCH="${1#*=}"
			[ "${BRANCH:0:1}" == "'" ] && [ "${BRANCH:0-1}" == "'" ] && BRANCH="${BRANCH:1:-1}"
			[ "${BRANCH:0:1}" == '"' ] && [ "${BRANCH:0-1}" == '"' ] && BRANCH="${BRANCH:1:-1}"
			;;
		-h|--help) usage;;
		*) echo "Unknown argument: $1" >&2; usage;;
	esac
	shift 1
done

##
# Simple check to enforce the script to be run as root
if [ $(id -u) -ne 0 ]; then
	echo "This script must be run as root or with sudo!" >&2
	exit 1
fi
##
# Simple wrapper to emulate `which -s`
#
# The -s flag is not available on all systems, so this function
# provides a consistent way to check for command existence
# without having to include '&>/dev/null' everywhere.
#
# Returns 0 on success, 1 on failure
#
# Arguments:
#   $1 - Command to check
#
# CHANGELOG:
#   2025.12.15 - Initial version (for a regression fix)
#
function cmd_exists() {
	local CMD="$1"
	which "$CMD" &>/dev/null
	return $?
}

##
# Get which firewall is enabled,
# or "none" if none located
function get_enabled_firewall() {
	if [ "$(systemctl is-active firewalld)" == "active" ]; then
		echo "firewalld"
	elif [ "$(systemctl is-active ufw)" == "active" ]; then
		echo "ufw"
	elif [ "$(systemctl is-active iptables)" == "active" ]; then
		echo "iptables"
	else
		echo "none"
	fi
}

##
# Get which firewall is available on the local system,
# or "none" if none located
#
# CHANGELOG:
#   2025.12.15 - Use cmd_exists to fix regression bug
#   2025.04.10 - Switch from "systemctl list-unit-files" to "which" to support older systems
function get_available_firewall() {
	if cmd_exists firewall-cmd; then
		echo "firewalld"
	elif cmd_exists ufw; then
		echo "ufw"
	elif systemctl list-unit-files iptables.service &>/dev/null; then
		echo "iptables"
	else
		echo "none"
	fi
}
##
# Check if the OS is "like" a certain type
#
# Returns 0 if true, 1 if false
#
# Usage:
#   if os_like debian; then ... ; fi
#
function os_like() {
	local OS="$1"

	if [ -f '/etc/os-release' ]; then
		ID="$(egrep '^ID=' /etc/os-release | sed 's:ID=::')"
		LIKE="$(egrep '^ID_LIKE=' /etc/os-release | sed 's:ID_LIKE=::')"

		if [[ "$LIKE" =~ "$OS" ]] || [ "$ID" == "$OS" ]; then
			return 0;
		fi
	fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_debian)" -eq 1 ]; then ... ; fi
#   if os_like_debian -q; then ... ; fi
#
function os_like_debian() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like debian || os_like ubuntu; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_ubuntu)" -eq 1 ]; then ... ; fi
#   if os_like_ubuntu -q; then ... ; fi
#
function os_like_ubuntu() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like ubuntu; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_rhel)" -eq 1 ]; then ... ; fi
#   if os_like_rhel -q; then ... ; fi
#
function os_like_rhel() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like rhel || os_like fedora || os_like rocky || os_like centos; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_suse)" -eq 1 ]; then ... ; fi
#   if os_like_suse -q; then ... ; fi
#
function os_like_suse() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like suse; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_arch)" -eq 1 ]; then ... ; fi
#   if os_like_arch -q; then ... ; fi
#
function os_like_arch() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if os_like arch; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	fi

	if [ $QUIET -eq 0 ]; then echo 0; fi
	return 1
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_bsd)" -eq 1 ]; then ... ; fi
#   if os_like_bsd -q; then ... ; fi
#
function os_like_bsd() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if [ "$(uname -s)" == 'FreeBSD' ]; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	else
		if [ $QUIET -eq 0 ]; then echo 0; fi
		return 1
	fi
}

##
# Check if the OS is "like" a certain type
#
# ie: "ubuntu" will be like "debian"
#
# Returns 0 if true, 1 if false
# Prints 1 if true, 0 if false
#
# Usage:
#   if [ "$(os_like_macos)" -eq 1 ]; then ... ; fi
#   if os_like_macos -q; then ... ; fi
#
function os_like_macos() {
	local QUIET=0
	while [ $# -ge 1 ]; do
		case $1 in
			-q)
				QUIET=1;;
		esac
		shift
	done

	if [ "$(uname -s)" == 'Darwin' ]; then
		if [ $QUIET -eq 0 ]; then echo 1; fi
		return 0;
	else
		if [ $QUIET -eq 0 ]; then echo 0; fi
		return 1
	fi
}
##
# Get the operating system version
#
# Just the major version number is returned
#
function os_version() {
	if [ "$(uname -s)" == 'FreeBSD' ]; then
		local _V="$(uname -K)"
		if [ ${#_V} -eq 6 ]; then
			echo "${_V:0:1}"
		elif [ ${#_V} -eq 7 ]; then
			echo "${_V:0:2}"
		fi

	elif [ -f '/etc/os-release' ]; then
		local VERS="$(egrep '^VERSION_ID=' /etc/os-release | sed 's:VERSION_ID=::')"

		if [[ "$VERS" =~ '"' ]]; then
			# Strip quotes around the OS name
			VERS="$(echo "$VERS" | sed 's:"::g')"
		fi

		if [[ "$VERS" =~ \. ]]; then
			# Remove the decimal point and everything after
			# Trims "24.04" down to "24"
			VERS="${VERS/\.*/}"
		fi

		if [[ "$VERS" =~ "v" ]]; then
			# Remove the "v" from the version
			# Trims "v24" down to "24"
			VERS="${VERS/v/}"
		fi

		echo "$VERS"

	else
		echo 0
	fi
}

##
# Install a package with the system's package manager.
#
# Uses Redhat's yum, Debian's apt-get, and SuSE's zypper.
#
# Usage:
#
# ```syntax-shell
# package_install apache2 php7.0 mariadb-server
# ```
#
# @param $1..$N string
#        Package, (or packages), to install.  Accepts multiple packages at once.
#
#
# CHANGELOG:
#   2026.01.09 - Cleanup os_like a bit and add support for RHEL 9's dnf
#   2025.04.10 - Set Debian frontend to noninteractive
#
function package_install (){
	echo "package_install: Installing $*..."

	if os_like_bsd -q; then
		pkg install -y $*
	elif os_like_debian -q; then
		DEBIAN_FRONTEND="noninteractive" apt-get -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" install -y $*
	elif os_like_rhel -q; then
		if [ "$(os_version)" -ge 9 ]; then
			dnf install -y $*
		else
			yum install -y $*
		fi
	elif os_like_arch -q; then
		pacman -Syu --noconfirm $*
	elif os_like_suse -q; then
		zypper install -y $*
	else
		echo 'package_install: Unsupported or unknown OS' >&2
		echo 'Please report this at https://github.com/eVAL-Agency/ScriptsCollection/issues' >&2
		exit 1
	fi
}

##
# Simple download utility function
#
# Uses either cURL or wget based on which is available
#
# Downloads the file to a temp location initially, then moves it to the final destination
# upon a successful download to avoid partial files.
#
# Returns 0 on success, 1 on failure
#
# Arguments:
#   --no-overwrite       Skip download if destination file already exists
#
# CHANGELOG:
#   2025.12.15 - Use cmd_exists to fix regression bug
#   2025.12.04 - Add --no-overwrite option to allow skipping download if the destination file exists
#   2025.11.23 - Download to a temp location to verify download was successful
#              - use which -s for cleaner checks
#   2025.11.09 - Initial version
#
function download() {
	# Argument parsing
	local SOURCE="$1"
	local DESTINATION="$2"
	local OVERWRITE=1
	local TMP=$(mktemp)
	shift 2

	while [ $# -ge 1 ]; do
    		case $1 in
    			--no-overwrite)
    				OVERWRITE=0
    				;;
    		esac
    		shift
    	done

	if [ -z "$SOURCE" ] || [ -z "$DESTINATION" ]; then
		echo "download: Missing required parameters!" >&2
		return 1
	fi

	if [ -f "$DESTINATION" ] && [ $OVERWRITE -eq 0 ]; then
		echo "download: Destination file $DESTINATION already exists, skipping download." >&2
		return 0
	fi

	if cmd_exists curl; then
		if curl -fsL "$SOURCE" -o "$TMP"; then
			mv $TMP "$DESTINATION"
			return 0
		else
			echo "download: curl failed to download $SOURCE" >&2
			return 1
		fi
	elif cmd_exists wget; then
		if wget -q "$SOURCE" -O "$TMP"; then
			mv $TMP "$DESTINATION"
			return 0
		else
			echo "download: wget failed to download $SOURCE" >&2
			return 1
		fi
	else
		echo "download: Neither curl nor wget is installed, cannot download!" >&2
		return 1
	fi
}

##
# Install UFW
#
function install_ufw() {
	if [ "$(os_like_rhel)" == 1 ]; then
		# RHEL/CentOS requires EPEL to be installed first
		package_install epel-release
	fi

	package_install ufw

	# Auto-enable a newly installed firewall
	ufw --force enable
	systemctl enable ufw
	systemctl start ufw

	# Auto-add the current user's remote IP to the whitelist (anti-lockout rule)
	local TTY_IP="$(who am i | awk '{print $NF}' | sed 's/[()]//g')"
	if [ -n "$TTY_IP" ]; then
		ufw allow from $TTY_IP comment 'Anti-lockout rule based on first install of UFW'
	fi
}

##
# Install firewalld
#
# CHANGELOG:
#   2026.03.16 - Switch awk to use $NF for better support
#
function install_firewalld() {
	package_install firewalld

	# Auto-add the current user's remote IP to the whitelist (anti-lockout rule)
	local TTY_IP="$(who am i | awk '{print $NF}' | sed 's/[()]//g')"
	if [ -n "$TTY_IP" ]; then
		# Anti-lockout rule based on first install of firewalld
		firewall-cmd --zone=trusted --add-source=$TTY_IP --permanent
	fi
}

##
# Install the system default firewall based on the OS type
#
# For Debian/Ubuntu, this installs UFW
# For RHEL/CentOS, this installs firewalld
# For SUSE, this installs firewalld
# For other OS types, this defaults to installing UFW
#
function firewall_install() {
	local FIREWALL

	FIREWALL=$(get_available_firewall)
	if [ "$FIREWALL" != "none" ]; then
		return
	fi

	if os_like_debian -q; then
		install_ufw
	elif os_like_rhel -q; then
		install_firewalld
	elif os_like_suse -q; then
		install_firewalld
	else
		install_ufw
	fi
}
##
# Determine if the current shell session is non-interactive.
#
# Checks NONINTERACTIVE, CI, DEBIAN_FRONTEND, and TERM.
#
# Returns 0 (true) if non-interactive, 1 (false) if interactive.
#
# CHANGELOG:
#   2025.12.16 - Remove TTY checks to avoid false positives in some environments
#   2025.11.23 - Initial version
#
function is_noninteractive() {
	# explicit flags
	case "${NONINTERACTIVE:-}${CI:-}" in
		1*|true*|TRUE*|True*|*CI* ) return 0 ;;
	esac

	# debian frontend
	if [ "${DEBIAN_FRONTEND:-}" = "noninteractive" ]; then
		return 0
	fi

	# dumb terminal
	if [ "${TERM:-}" = "dumb" ]; then
		return 0
	fi

	return 1
}

##
# Prompt user for a text response
#
# Arguments:
#   --default="..."   Default text to use if no response is given
#
# Returns:
#   text as entered by user
#
# CHANGELOG:
#   2025.11.23 - Use is_noninteractive to handle non-interactive mode
#   2025.01.01 - Initial version
#
function prompt_text() {
	local DEFAULT=""
	local PROMPT="Enter some text"
	local RESPONSE=""

	while [ $# -ge 1 ]; do
		case $1 in
			--default=*) DEFAULT="${1#*=}";;
			*) PROMPT="$1";;
		esac
		shift
	done

	echo "$PROMPT" >&2
	echo -n '> : ' >&2

	if is_noninteractive; then
		# In non-interactive mode, return the default value
		echo $DEFAULT
		return
	fi

	read RESPONSE
	if [ "$RESPONSE" == "" ]; then
		echo "$DEFAULT"
	else
		echo "$RESPONSE"
	fi
}

##
# Prompt user for a yes or no response
#
# Arguments:
#   --invert            Invert the response (yes becomes 0, no becomes 1)
#   --default-yes       Default to yes if no response is given
#   --default-no        Default to no if no response is given
#   -q                  Quiet mode (no output text after response)
#
# Returns:
#   1 for yes, 0 for no (or inverted if --invert is set)
#
# CHANGELOG:
#   2025.12.16 - Add text output for non-interactive and empty responses
#   2025.11.23 - Use is_noninteractive to handle non-interactive mode
#   2025.11.09 - Add -q (quiet) option to suppress output after prompt (and use return value)
#   2025.01.01 - Initial version
#
function prompt_yn() {
	local TRUE=0 # Bash convention: 0 is success/true
	local YES=1
	local FALSE=1 # Bash convention: non-zero is failure/false
	local NO=0
	local DEFAULT="n"
	local DEFAULT_CODE=1
	local PROMPT="Yes or no?"
	local RESPONSE=""
	local QUIET=0

	while [ $# -ge 1 ]; do
		case $1 in
			--invert) YES=0; NO=1 TRUE=1; FALSE=0;;
			--default-yes) DEFAULT="y";;
			--default-no) DEFAULT="n";;
			-q) QUIET=1;;
			*) PROMPT="$1";;
		esac
		shift
	done

	echo "$PROMPT" >&2
	if [ "$DEFAULT" == "y" ]; then
		DEFAULT_TEXT="yes"
		DEFAULT="$YES"
		DEFAULT_CODE=$TRUE
		echo -n "> (Y/n): " >&2
	else
		DEFAULT_TEXT="no"
		DEFAULT="$NO"
		DEFAULT_CODE=$FALSE
		echo -n "> (y/N): " >&2
	fi

	if is_noninteractive; then
		# In non-interactive mode, return the default value
		echo "$DEFAULT_TEXT (default non-interactive)" >&2
		if [ $QUIET -eq 0 ]; then
			echo $DEFAULT
		fi
		return $DEFAULT_CODE
	fi

	read RESPONSE
	case "$RESPONSE" in
		[yY]*)
			if [ $QUIET -eq 0 ]; then
				echo $YES
			fi
			return $TRUE;;
		[nN]*)
			if [ $QUIET -eq 0 ]; then
				echo $NO
			fi
			return $FALSE;;
		"")
			echo "$DEFAULT_TEXT (default choice)" >&2
			if [ $QUIET -eq 0 ]; then
				echo $DEFAULT
			fi
			return $DEFAULT_CODE;;
		*)
			if [ $QUIET -eq 0 ]; then
				echo $DEFAULT
			fi
			return $DEFAULT_CODE;;
	esac
}
##
# Print a header message
#
# CHANGELOG:
#   2025.11.09 - Port from _common to bz_eval_tui
#   2024.12.25 - Initial version
#
function print_header() {
	local header="$1"
	echo "================================================================================"
	printf "%*s\n" $(((${#header}+80)/2)) "$header"
    echo ""
}

##
# Install SteamCMD
#
# CHANGELOG:
#
#   2025.12.16 - Ensure steam GPG key is readable by apt
#   2025.11.09 - Switch to using download to support curl/wget abstraction
#   2025.11.03 - Add support for Debian 13
#   2024.12.23 - Add support for non-interactive acceptance of Steam license
#   2024.12.22 - Initial version
#
function install_steamcmd() {
	echo "Installing SteamCMD..."

	TYPE_DEBIAN="$(os_like_debian)"
	TYPE_UBUNTU="$(os_like_ubuntu)"
	OS_VERSION="$(os_version)"

	# Preliminary requirements
	if [ "$TYPE_UBUNTU" == 1 ]; then
		add-apt-repository -y multiverse
		dpkg --add-architecture i386
		apt update

		# By using this script, you agree to the Steam license agreement at https://store.steampowered.com/subscriber_agreement/
		# and the Steam privacy policy at https://store.steampowered.com/privacy_agreement/
		# Since this is meant to support unattended installs, we will forward your acceptance of their license.
		echo steam steam/question select "I AGREE" | debconf-set-selections
		echo steam steam/license note '' | debconf-set-selections

		apt install -y steamcmd
	elif [ "$TYPE_DEBIAN" == 1 ]; then
		dpkg --add-architecture i386
		apt update

		if [ "$OS_VERSION" -le 12 ]; then
			apt install -y software-properties-common apt-transport-https dirmngr ca-certificates lib32gcc-s1

			# Enable "non-free" repos for Debian (for steamcmd)
			# https://stackoverflow.com/questions/76688863/apt-add-repository-doesnt-work-on-debian-12
			add-apt-repository -y -U http://deb.debian.org/debian -c non-free-firmware -c non-free
			if [ $? -ne 0 ]; then
				echo "Workaround failed to add non-free repos, trying new method instead"
				apt-add-repository -y non-free
			fi
		else
			# Debian Trixie and later
			if [ -e /etc/apt/sources.list ]; then
				if ! grep -q ' non-free ' /etc/apt/sources.list; then
					sed -i 's/main/main non-free-firmware non-free contrib/g' /etc/apt/sources.list
				fi
			elif [ -e /etc/apt/sources.list.d/debian.sources ]; then
				if ! grep -q ' non-free ' /etc/apt/sources.list.d/debian.sources; then
					sed -i 's/main/main non-free-firmware non-free contrib/g' /etc/apt/sources.list.d/debian.sources
				fi
			else
				echo "Could not find a sources.list file to enable non-free repos" >&2
				exit 1
			fi
		fi

		# Install steam repo
		download http://repo.steampowered.com/steam/archive/stable/steam.gpg /usr/share/keyrings/steam.gpg
		chmod +r /usr/share/keyrings/steam.gpg
		echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/steam.gpg] http://repo.steampowered.com/steam/ stable steam" > /etc/apt/sources.list.d/steam.list

		# By using this script, you agree to the Steam license agreement at https://store.steampowered.com/subscriber_agreement/
		# and the Steam privacy policy at https://store.steampowered.com/privacy_agreement/
		# Since this is meant to support unattended installs, we will forward your acceptance of their license.
		echo steam steam/question select "I AGREE" | debconf-set-selections
		echo steam steam/license note '' | debconf-set-selections

		# Install steam binary and steamcmd
		apt update
		apt install -y steamcmd
	else
		echo 'Unsupported or unknown OS' >&2
		exit 1
	fi
}
##
# Install the management script from the project's repo
#
# Expects the following variables:
#   GAME_USER    - User account to install the game under
#   GAME_DIR     - Directory to install the game into
#
# @param $1 Repo Name (e.g., user/repo)
# @param $2 Branch Name (default: main)
#
# CHANGELOG:
#   20260301 - Update to install warlock-manager from github (along with its dependencies) as a pip package
#
function install_warlock_manager() {
	print_header "Performing install_management"

	# Install management console and its dependencies
	local SRC=""
	local REPO="$1"
	local BRANCH="${2:-main}"

	SRC="https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/dist/manage.py"

	if ! download "$SRC" "$GAME_DIR/manage.py"; then
		echo "Could not download management script!" >&2
		exit 1
	fi

	chown $GAME_USER:$GAME_USER "$GAME_DIR/manage.py"
	chmod +x "$GAME_DIR/manage.py"

	# Install configuration definitions
	cat > "$GAME_DIR/configs.yaml" <<EOF
service:
  - name: Server Name
    key: name
    section: flag
    default: "My server"
    type: str
    help: "The name of your server as it appears in server browsers."
  - name: Game Port
    key: port
    section: flag
    default: 2456
    type: int
    help: "The port number your server will use for game connections."
  - name: World Name
    key: world
    section: flag
    default: "Dedicated"
    type: str
    help: "The name of the world your server will load or create."
  - name: Join Password
    key: password
    section: flag
    default: "secret"
    type: str
    help: "The password required for players to join your server."
  - name: Save Directory
    key: savedir
    section: flag
    type: str
    help: "Override the default save path"
  - name: Public Server
    key: public
    section: flag
    type: int
    default: 1
    options:
      - 0
      - 1
    help: "Set to 1 to make this a public server listed on the server browser, or 0 to make it private."
  - name: Log File
    key: logFile
    section: flag
    type: str
    help: "Path to a file where server logs will be written."
  - name: Backups
    key: backups
    section: flag
    type: int
    default: 4
    help: "Number of backup save files to keep."
  - name: Backup Short Interval
    key: backupshort
    section: flag
    type: int
    default: 7200
    help: "Interval in seconds for short interval backups."
  - name: Backup Long Interval
    key: backuplong
    section: flag
    type: int
    default: 43200
    help: "Interval in seconds for long interval backups."
  - name: Crossplay Enabled
    key: crossplay
    section: flag
    type: bool
    default: true
    help: "Enable crossplay support for different platforms."
  - name: Instance ID
    key: instanceid
    section: flag
    type: str
    help: "Unique identifier for this server instance (used for multi-instance setups)."
  - name: Preset
    key: preset
    section: flag
    type: str
    options:
      - Normal
      - Casual
      - Easy
      - Hard
      - Hardcore
      - Immersive
      - Hammer
    help: "Specify a preset configuration for the server."
  - name: Modifier (Combat)
    key: modifier combat
    section: flag
    type: str
    options:
      - veryeasy
      - easy
      - hard
      - veryhard
    help: "Set the combat difficulty modifier."
  - name: Modifier (Death Penalty)
    key: modifier deathpenalty
    section: flag
    type: str
    options:
      - casual
      - veryeasy
      - easy
      - hard
      - hardcore
    help: "Set the death penalty modifier."
  - name: Modifier (Resources)
    key: modifier resources
    section: flag
    type: str
    options:
      - muchless
      - less
      - more
      - muchmore
      - most
    help: "Set the resource availability modifier."
  - name: Modifier (Portals)
    key: modifier portals
    section: flag
    type: str
    options:
      - casual
      - hard
      - veryhard
    help: "Portals modifier in the game."
  - name: Modifier - No Build Cost
    key: setkey nobuildcost
    section: flag
    type: bool
    default: false
    help: "If true, building structures will have no resource cost."
  - name: Modifier - Player Events
    key: setkey playerevents
    section: flag
    type: bool
    default: false
    help: "If true, player events are enabled."
  - name: Modifier - Passive Mobs
    key: setkey passivemobs
    section: flag
    type: bool
    default: false
    help: "If true, passive mobs are enabled."
  - name: Modifier - No Map
    key: setkey nomap
    section: flag
    type: bool
    default: false
    help: "If true, no map will be available."
manager:
  - name: Shutdown Warning 5 Minutes
    section: Messages
    key: shutdown_5min
    type: str
    default: Server is shutting down in 5 minutes
    help: "Custom message broadcasted to players 5 minutes before server shutdown."
  - name: Shutdown Warning 4 Minutes
    section: Messages
    key: shutdown_4min
    type: str
    default: Server is shutting down in 4 minutes
    help: "Custom message broadcasted to players 4 minutes before server shutdown."
  - name: Shutdown Warning 3 Minutes
    section: Messages
    key: shutdown_3min
    type: str
    default: Server is shutting down in 3 minutes
    help: "Custom message broadcasted to players 3 minutes before server shutdown."
  - name: Shutdown Warning 2 Minutes
    section: Messages
    key: shutdown_2min
    type: str
    default: Server is shutting down in 2 minutes
    help: "Custom message broadcasted to players 2 minutes before server shutdown."
  - name: Shutdown Warning 1 Minute
    section: Messages
    key: shutdown_1min
    type: str
    default: Server is shutting down in 1 minute
    help: "Custom message broadcasted to players 1 minute before server shutdown."
  - name: Shutdown Warning 30 Seconds
    section: Messages
    key: shutdown_30sec
    type: str
    default: Server is shutting down in 30 seconds!
    help: "Custom message broadcasted to players 30 seconds before server shutdown."
  - name: Shutdown Warning NOW
    section: Messages
    key: shutdown_now
    type: str
    default: Server is shutting down NOW!
    help: "Custom message broadcasted to players immediately before server shutdown."
  - name: Instance Started (Discord)
    section: Discord
    key: instance_started
    type: str
    default: "{instance} has started! :rocket:"
    help: "Custom message sent to Discord when the server starts, use '{instance}' to insert the map name"
  - name: Instance Stopping (Discord)
    section: Discord
    key: instance_stopping
    type: str
    default: ":small_red_triangle_down: {instance} is shutting down"
    help: "Custom message sent to Discord when the server stops, use '{instance}' to insert the map name"
  - name: Discord Enabled
    section: Discord
    key: enabled
    type: bool
    default: false
    help: "Enables or disables Discord integration for server status updates."
  - name: Discord Webhook URL
    section: Discord
    key: webhook
    type: str
    help: "The webhook URL for sending server status updates to a Discord channel."
EOF
	chown $GAME_USER:$GAME_USER "$GAME_DIR/configs.yaml"

	# Most games use .settings.ini for manager settings
	touch "$GAME_DIR/.settings.ini"
	chown $GAME_USER:$GAME_USER "$GAME_DIR/.settings.ini"

	# A python virtual environment is now required by Warlock-based managers.
	sudo -u $GAME_USER python3 -m venv "$GAME_DIR/.venv"
	sudo -u $GAME_USER "$GAME_DIR/.venv/bin/pip" install --upgrade pip
	sudo -u $GAME_USER "$GAME_DIR/.venv/bin/pip" install warlock-manager@git+https://github.com/BitsNBytes25/Warlock-Manager.git@release-v2
}


print_header "$GAME_DESC *unofficial* Installer ${INSTALLER_VERSION}"

############################################
## Installer Actions
############################################

##
# Install the VEIN game server using Steam
#
# Expects the following variables:
#   GAME_USER    - User account to install the game under
#   GAME_DIR     - Directory to install the game into
#   STEAM_ID     - Steam App ID of the game
#   GAME_DESC    - Description of the game (for logging purposes)
#   GAME_SERVICE - Service name to install with Systemd
#   SAVE_DIR     - Directory to store game save files
#
function install_application() {
	print_header "Performing install_application"

	# Create the game user account
	# This will create the account with no password, so if you need to log in with this user,
	# run `sudo passwd $GAME_USER` to set a password.
	if [ -z "$(getent passwd $GAME_USER)" ]; then
		useradd -m -U $GAME_USER
	fi

	# Ensure the target directory exists and is owned by the game user
	if [ ! -d "$GAME_DIR" ]; then
		mkdir -p "$GAME_DIR"
		chown $GAME_USER:$GAME_USER "$GAME_DIR"
	fi

	# Preliminary requirements
	package_install curl sudo python3-venv unzip

	if [ "$FIREWALL" == "1" ]; then
		if [ "$(get_enabled_firewall)" == "none" ]; then
			# No firewall installed, go ahead and install the system default firewall
			firewall_install
		fi
	fi

	[ -e "$GAME_DIR/AppFiles" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/AppFiles"
	[ -e "$GAME_DIR/Environments" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/Environments"


	install_steamcmd

	install_warlock_manager "$REPO" "$BRANCH"

	#if [ "$MOD_OR_VANILLA" == "modded" ]; then
	#	if ! install_bepinex; then
	#		echo "BepInEx installation failed, reverting to vanilla!" >&2
	#		MOD_OR_VANILLA="vanilla"
	#	fi
	#fi

	# Install installer (this script) for uninstallation or manual work
	download "https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/dist/installer.sh" "$GAME_DIR/installer.sh"
	chmod +x "$GAME_DIR/installer.sh"
	chown $GAME_USER:$GAME_USER "$GAME_DIR/installer.sh"

	# Register this application install with Warlock so it can be picked up by the web manager.
	if [ -n "$WARLOCK_GUID" ]; then
		[ -d "/var/lib/warlock" ] || mkdir -p "/var/lib/warlock"
		echo -n "$GAME_DIR" > "/var/lib/warlock/${WARLOCK_GUID}.app"
	fi
}

function install_bepinex() {
	print_header "Installing BepInEx for Valheim"

	DEST="$(echo "$BEPINEX_URL" | sed 's:.*/\(.*\)/\([0-9\.]*\)/:\1-\2.zip:')"
	[ -e "$GAME_DIR/Packages" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/Packages"

	if ! download "$BEPINEX_URL" "$GAME_DIR/Packages/$DEST" --no-overwrite; then
		echo "Could not download BepInExPack_Valheim from Thunderstore!" >&2
		return 1
	fi

	chown $GAME_USER:$GAME_USER -R "$GAME_DIR/Packages"
	sudo -u $GAME_USER unzip -o "$GAME_DIR/Packages/$DEST" "BepInExPack_Valheim/*" -d "$GAME_DIR/AppFiles/"
	sudo -u $GAME_USER mv "$GAME_DIR/AppFiles/BepInExPack_Valheim/"* "$GAME_DIR/AppFiles/"
	sudo -u $GAME_USER rm -rf "$GAME_DIR/AppFiles/BepInExPack_Valheim/"
	return 0
}

##
# Perform any steps necessary for upgrading an existing installation.
#
function upgrade_application() {
	print_header "Existing installation detected, performing upgrade"

	# Migrate existing service to new format
	if [ -e /etc/systemd/system/valheim-server.service ] && [ ! -e "$GAME_DIR/Environments" ]; then
		sudo -u $GAME_USER mkdir -p "$GAME_DIR/Environments"
		egrep '^Environment' /etc/systemd/system/valheim-server.service | sed 's:^Environment=::' > "$GAME_DIR/Environments/valheim-server.env"
		chown $GAME_USER:$GAME_USER -R "$GAME_DIR/Environments/valheim-server.env"
	fi
}

function postinstall() {
	print_header "Performing postinstall"

	# First run setup
	$GAME_DIR/manage.py first-run
}

##
# Uninstall the game server
#
# Expects the following variables:
#   GAME_DIR     - Directory where the game is installed
#   GAME_SERVICE - Service name used with Systemd
#   SAVE_DIR     - Directory where game save files are stored
#
function uninstall_application() {
	print_header "Performing uninstall_application"

	systemctl disable $GAME_SERVICE
	systemctl stop $GAME_SERVICE

	# Service files
	[ -e "/etc/systemd/system/${GAME_SERVICE}.service" ] && rm "/etc/systemd/system/${GAME_SERVICE}.service"
	[ -e "/etc/systemd/system/${GAME_SERVICE}.service.d" ] && rm -r "/etc/systemd/system/${GAME_SERVICE}.service.d"

	# Game files
	[ -d "$GAME_DIR" ] && rm -rf "$GAME_DIR/AppFiles"

	# Management scripts
	[ -e "$GAME_DIR/manage.py" ] && rm "$GAME_DIR/manage.py"
	[ -e "$GAME_DIR/configs.yaml" ] && rm "$GAME_DIR/configs.yaml"
	[ -d "$GAME_DIR/.venv" ] && rm -rf "$GAME_DIR/.venv"

	if [ -n "$WARLOCK_GUID" ]; then
		# unregister Warlock
		[ -e "/var/lib/warlock/${WARLOCK_GUID}.app" ] && rm "/var/lib/warlock/${WARLOCK_GUID}.app"
	fi
}

############################################
## Pre-exec Checks
############################################

if [ $MODE_UNINSTALL -eq 1 ]; then
	MODE="uninstall"
elif [ -e "$GAME_DIR/AppFiles" ]; then
	MODE="reinstall"
else
	# Default to install mode
	MODE="install"
fi


if [ -e "$GAME_DIR/Environments" ]; then
	# Check for existing service files to determine if the service is running.
	# This is important to prevent conflicts with the installer trying to modify files while the service is running.
	for envfile in "$GAME_DIR/Environments/"*.env; do
		SERVICE=$(basename "$envfile" .env)
		# If there are no services, this will just be '*.env'.
		if [ "$SERVICE" != "*" ]; then
			if systemctl -q is-active $SERVICE; then
				echo "$GAME_DESC service is currently running, please stop all instances before running this installer."
				echo "You can do this with: sudo systemctl stop $SERVICE"
				exit 1
			fi
		fi
	done
fi


if [ -n "$OVERRIDE_DIR" ]; then
	# User requested to change the install dir!
	# This changes the GAME_DIR from the default location to wherever the user requested.
	if [ -e "/var/lib/warlock/${WARLOCK_GUID}.app" ] ; then
		# Check for existing installation directory based on Warlock registration
		GAME_DIR="$(cat "/var/lib/warlock/${WARLOCK_GUID}.app")"
		if [ "$GAME_DIR" != "$OVERRIDE_DIR" ]; then
			echo "ERROR: $GAME_DESC already installed in $GAME_DIR, cannot override to $OVERRIDE_DIR" >&2
			echo "If you want to move the installation, please uninstall first and then re-install to the new location." >&2
			exit 1
		fi
	fi

	GAME_DIR="$OVERRIDE_DIR"
	echo "Using ${GAME_DIR} as the installation directory based on explicit argument"
elif [ -e "/var/lib/warlock/${WARLOCK_GUID}.app" ]; then
	# Check for existing installation directory based on service file
	GAME_DIR="$(cat "/var/lib/warlock/${WARLOCK_GUID}.app")"
	echo "Detected installation directory of ${GAME_DIR} based on service registration"
else
	echo "Using default installation directory of ${GAME_DIR}"
fi



############################################
## Installer
############################################


if [ "$MODE" == "install" ]; then

	if [ $SKIP_FIREWALL -eq 1 ]; then
		FIREWALL=0
	elif [ $EXISTING -eq 0 ] && prompt_yn -q --default-yes "Install system firewall?"; then
		FIREWALL=1
	else
		FIREWALL=0
	fi

	install_application

	postinstall

	# Print some instructions and useful tips
    print_header "$GAME_DESC Installation Complete"
fi

# Operations needed to be performed during a reinstallation / upgrade
if [ "$MODE" == "reinstall" ]; then

	FIREWALL=0

	upgrade_application

	install_application

	postinstall

	# Print some instructions and useful tips
    print_header "$GAME_DESC Installation Complete"
fi

if [ "$MODE" == "uninstall" ]; then
	if [ $NONINTERACTIVE -eq 0 ]; then
		if prompt_yn -q --invert --default-no "This will remove all game binary content"; then
			exit 1
		fi
		if prompt_yn -q --invert --default-no "This will remove all player and map data"; then
			exit 1
		fi
	fi

	if prompt_yn -q --default-yes "Perform a backup before everything is wiped?"; then
		$GAME_DIR/manage.py backup
	fi

	uninstall_application
fi
