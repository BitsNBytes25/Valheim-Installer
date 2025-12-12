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
#   MODE_UNINSTALL=--uninstall - Perform an uninstallation
#   OVERRIDE_DIR=--dir=<path> - Use a custom installation directory instead of the default (optional)
#   SKIP_FIREWALL=--skip-firewall - Do not install or configure a system firewall
#   NONINTERACTIVE=--non-interactive - Run the installer in non-interactive mode (useful for scripted installs)
#   MOD_OR_VANILLA=--modded=<auto|modded|vanilla> - Choose between modded or vanilla server DEFAULT=auto
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


# compile:usage
# compile:argparse
# scriptlet:_common/require_root.sh
# scriptlet:_common/get_firewall.sh
# scriptlet:_common/package_install.sh
# scriptlet:_common/download.sh
# scriptlet:bz_eval_tui/prompt_text.sh
# scriptlet:bz_eval_tui/prompt_yn.sh
# scriptlet:bz_eval_tui/print_header.sh
# scriptlet:ufw/install.sh
# scriptlet:steam/install-steamcmd.sh
# scriptlet:warlock/install_warlock_manager.sh

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

	# Preliminary requirements
	package_install curl sudo python3-venv unzip

	if [ "$FIREWALL" == "1" ]; then
		if [ "$(get_enabled_firewall)" == "none" ]; then
			# No firewall installed, go ahead and install UFW
			install_ufw
		fi
	fi

	[ -e "$GAME_DIR/AppFiles" ] || sudo -u $GAME_USER mkdir -p "$GAME_DIR/AppFiles"


	install_steamcmd

	install_warlock_manager "$REPO"

	if ! $GAME_DIR/manage.py --update; then
		echo "Could not install $GAME_DESC, exiting" >&2
		exit 1
	fi

	if [ "$MOD_OR_VANILLA" == "modded" ]; then
		if ! install_bepinex; then
			echo "BepInEx installation failed, reverting to vanilla!" >&2
			MOD_OR_VANILLA="vanilla"
		fi
	fi

	# Install system service file to be loaded by systemd
	if [ "$MOD_OR_VANILLA" == "modded" ]; then
		cat > /etc/systemd/system/${GAME_SERVICE}.service <<EOF
# script:systemd-modded-template.service
EOF
	else
    	cat > /etc/systemd/system/${GAME_SERVICE}.service <<EOF
# script:systemd-template.service
EOF
	fi

	if [ ! -e "/etc/systemd/system/${GAME_SERVICE}.service.d/override.conf" ]; then
		# Install system override file to be loaded by systemd
		[ -d "/etc/systemd/system/${GAME_SERVICE}.service.d" ] || mkdir -p "/etc/systemd/system/${GAME_SERVICE}.service.d"
		cat > /etc/systemd/system/${GAME_SERVICE}.service.d/override.conf <<EOF
# script:systemd-override.service
EOF
	fi
    systemctl daemon-reload

	if [ -n "$WARLOCK_GUID" ]; then
		# Register Warlock
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

function postinstall() {
	print_header "Performing postinstall"

	# First run setup
	$GAME_DIR/manage.py --first-run
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
else
	# Default to install mode
	MODE="install"
fi


if systemctl -q is-active $GAME_SERVICE; then
	echo "$GAME_DESC service is currently running, please stop it before running this installer."
	echo "You can do this with: sudo systemctl stop $GAME_SERVICE"
	exit 1
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

if [ -e "/etc/systemd/system/${GAME_SERVICE}.service" ]; then
	EXISTING=1
else
	EXISTING=0
fi

if [ "$MOD_OR_VANILLA" == "auto" ]; then
	# Automatic; determine if BepinEx is currently installed.
	if [ -e "$GAME_DIR/AppFiles/BepInEx" ]; then
		MOD_OR_VANILLA="modded"
	else
		MOD_OR_VANILLA="vanilla"
	fi
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
		$GAME_DIR/manage.py --backup
	fi

	uninstall_application
fi
