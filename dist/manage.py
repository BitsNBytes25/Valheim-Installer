#!/usr/bin/env python3
import json
import logging
import os
import shutil
import zipfile
import sys
# Include the virtual environment site-packages in sys.path
here = os.path.dirname(os.path.realpath(__file__))
if not os.path.exists(os.path.join(here, '.venv')):
	print('Python environment not setup')
	exit(1)
sys.path.insert(
	0,
	os.path.join(
		here,
		'.venv',
		'lib',
		'python' + '.'.join(sys.version.split('.')[:2]), 'site-packages'
	)
)
from warlock_manager.apps.steam_app import SteamApp
from warlock_manager.formatters.cli_formatter import cli_formatter
from warlock_manager.libs.download import download_json, download_file
from warlock_manager.libs.version import is_version_newer
from warlock_manager.services.base_service import BaseService
from warlock_manager.config.ini_config import INIConfig
from warlock_manager.libs.app_runner import app_runner
from warlock_manager.libs.firewall import Firewall
from warlock_manager.libs import utils
from warlock_manager.mods.warlock_nexus_mod import WarlockNexusMod
# To allow running as a standalone script without installing the package, include the venv path for imports.
# This will set the include path for this path to .venv to allow packages installed therein to be utilized.
#
# IMPORTANT - any imports that are needed for the script to run must be after this,
# otherwise the imports will fail when running as a standalone script.

# Import the appropriate type of handler for the game installer.
# Common options are:
# from warlock_manager.apps.base_app import BaseApp

# Import the appropriate type of handler for the game services.
# Common options are:
# from warlock_manager.services.rcon_service import RCONService
# from warlock_manager.services.socket_service import SocketService
# from warlock_manager.services.http_service import HTTPService

# Import the various configuration handlers used by this game.
# Common options are:
# from warlock_manager.config.cli_config import CLIConfig
# from warlock_manager.config.json_config import JSONConfig
# from warlock_manager.config.properties_config import PropertiesConfig
# from warlock_manager.config.unreal_config import UnrealConfig

# Load the application runner responsible for interfacing with CLI arguments
# and providing default functionality for running the manager.

# If your script manages the firewall, (recommended), import the Firewall library

# Utilities provided by Warlock that are common to many applications

# This game supports full mod support
# from warlock_manager.mods.base_mod import BaseMod


class GameMod(WarlockNexusMod):
	def calculate_files(self):
		"""
		Calculate the files in this mod that are to be installed.

		:return:
		"""
		self.files = {}
		target_archive = os.path.join(utils.get_app_directory(), 'Packages', self.package)
		with zipfile.ZipFile(target_archive, 'r') as zip_ref:
			for member in zip_ref.namelist():
				if member in ['CHANGELOG.md', 'icon.png', 'manifest.json', 'README.md', 'LICENSE.md']:
					# Skip common non-essential files
					continue

				if member.startswith('plugins/'):
					# These can be extract directly, they're probably well formatted
					self.files['@:%s' % member] = os.path.join('BepInEx', member)
				elif member.startswith('BepInExPack_Valheim/'):
					# These need to be pulled out of the directory they're in and should be in the root
					self.files['@:%s' % member] = member.replace('BepInExPack_Valheim/', '')
				else:
					# A number of developers just throw their DLLs in the root level of their zip
					self.files['@:%s' % member] = os.path.join('BepInEx', 'plugins', member)


class GameApp(SteamApp):
	"""
	Game application manager
	"""

	def __init__(self):
		super().__init__()

		self.name = 'Valheim'
		self.desc = 'Valheim game server'
		self.steam_id = '896660'
		self.service_handler = GameService
		self.mod_handler = GameMod
		self.service_prefix = 'valheim-'

		self.disabled_features = {'api'}

		self.configs = {
			'manager': INIConfig('manager', os.path.join(utils.get_app_directory(), '.settings.ini'))
		}
		self.load()

	def first_run(self) -> bool:
		"""
		Perform any first-run configuration needed for this game

		:return:
		"""

		if os.geteuid() != 0:
			logging.error('Please run this script with sudo to perform first-run configuration.')
			return False

		super().first_run()
		utils.makedirs(os.path.join(utils.get_app_directory(), 'Configs'))
		utils.makedirs(os.path.join(utils.get_app_directory(), 'Packages'))

		# Install the game with Steam.
		self.update()

		services = self.get_services()
		if len(services) == 0:
			# No services detected, create one.
			logging.info('No services detected, creating one...')
			self.create_service('valheim-server')
		else:
			# Ensure services match new format
			for service in services:
				logging.info('Ensuring %s service file is on latest format' % service.service)
				service.build_systemd_config()
				service.reload()
		return True

	def remove(self):
		super().remove()

		shutil.rmtree(os.path.join(utils.get_app_directory(), 'Configs'))
		shutil.rmtree(os.path.join(utils.get_app_directory(), 'Packages'))


class GameService(BaseService):
	"""
	Service definition and handler
	"""
	def __init__(self, service: str, game: GameApp):
		"""
		Initialize and load the service definition
		:param file:
		"""
		super().__init__(service, game)
		self.service = service
		self.game = game
		self.configs = {
			'service': INIConfig('service', os.path.join(utils.get_app_directory(), 'Configs', 'service.%s.ini' % self.service))
		}
		self.load()

	def get_executable(self) -> str:
		"""
		Get the full executable for this game service
		:return:
		"""
		path = os.path.join(self.get_app_directory(), 'valheim_server.x86_64')

		# Add arguments for the service
		args = cli_formatter(self.configs['service'], 'flag')
		if args:
			path += ' ' + args

		return path

	def get_environment(self) -> dict:
		"""
		Get the environment variables for this service as a dictionary

		:return:
		"""

		if self.get_option_value('Modded Instance'):
			return {
				'XDG_RUNTIME_DIR': '/run/user/%s' % utils.get_app_uid(),
				'LD_PRELOAD': os.path.join(self.get_app_directory(), 'doorstop_libs', 'libdoorstop_x64.so'),
				'LD_LIBRARY_PATH': os.path.join(self.get_app_directory(), 'doorstop_libs') + ':' + os.path.join(self.get_app_directory(), 'linux64'),
				'SteamAppId': '892970',
				'DOORSTOP_ENABLED': '1',
				'DOORSTOP_TARGET_ASSEMBLY': os.path.join(self.get_app_directory(), 'BepInEx', 'core', 'BepInEx.Preloader.dll')
			}
		else:
			return {
				'XDG_RUNTIME_DIR': '/run/user/%s' % utils.get_app_uid(),
				'LD_LIBRARY_PATH': os.path.join(self.get_app_directory(), 'linux64'),
				'SteamAppId': '892970'
			}

	def get_save_directory(self) -> str:
		"""
		Get the parent directory that contains the Save files for this game

		By default this is just the app directory (AppFiles or AppFiles/{servicename}),
		but this can be changed if the game saves files outside this directory.

		:return:
		"""
		return os.path.join(utils.get_home_directory(), '.config/unity3d/IronGate/Valheim')

	def get_save_files(self) -> list | None:
		"""
		Get the list of supplemental files or directories for this game, or None if not applicable

		This list of files **should not** be fully resolved, and will use `self.get_app_directory()` as the base path.
		For example, to return `AppFiles/SaveData` and `AppFiles/Config`:

		```python
		return ['SaveData', 'Config']
		```

		:return:
		"""
		world_name = self.get_option_value('World Name')
		return [
			'worlds_local/%s.fwl' % world_name,
			'worlds_local/%s.db' % world_name,
			'adminlist.txt',
			'bannedlist.txt',
			'permittedlist.txt'
		]

	def option_value_updated(self, option: str, previous_value, new_value) -> bool | None:
		"""
		Handle any special actions needed when an option value is updated
		:param option:
		:param previous_value:
		:param new_value:
		:return:
		"""
		success = None

		# Special option actions
		if option == 'Game Port':
			# Update firewall for game port change
			if previous_value:
				Firewall.remove(int(previous_value), 'udp')
				Firewall.remove(int(previous_value)+1, 'udp')
			Firewall.allow(int(new_value), 'udp', '%s game port' % self.game.name)
			Firewall.allow(int(new_value)+1, 'udp', '%s query port' % self.game.name)
			success = True
		elif option == 'Modded Instance':
			if new_value:
				# Install BepInEx
				mod = GameMod.get_mod(self, 'thunderstore', 'denikson-BepInExPack_Valheim')
				if mod:
					self.add_mod(mod, True)
					success = True
				else:
					logging.error('Could not automatically install BepInEx, please install it manually.')
					success = False
			# Regenerate the environmental file
			with open(self._env_file, 'w') as f:
				env = self.get_environment()
				for key in env:
					f.write('%s=%s\n' % (key, env[key]))

		# Reload systemd to apply changes
		self.build_systemd_config()
		self.reload()
		return success

	def create_service(self):
		"""
		Create the systemd service for this game, including the service file and environment file
		:return:
		"""

		# Ensure some required parameters are set
		self.set_option('Server Name', self.service)
		self.set_option('World Name', self.service)
		self.option_ensure_set('Join Password')
		self.set_option('Instance ID', self.service)

		super().create_service()

	def get_enabled_mods(self) -> list[GameMod]:
		"""
		Get all enabled mods that are locally available on this service
		Valheim doesn't support tracking mods natively, so we use a flat file to track installed mods.

		:return:
		"""
		mods = GameMod.get_registered_mods()
		enabled_mods = []
		for mod in mods:
			mod_check_file = os.path.join(self.get_app_directory(), '.mods', mod.id)
			if os.path.exists(mod_check_file):
				with open(mod_check_file, 'r') as f:
					if f.read().strip() == mod.version:
						enabled_mods.append(mod)
		return enabled_mods

	def add_mod(self, mod: 'GameMod', force: bool = False) -> bool:
		"""
		Install a mod

		:param mod: Mod to install
		:param force: Force the installation even if the mod is already installed
		:return:
		"""
		logging.info('Installing mod %s' % mod.name)

		enabled_mod = self.get_mod(mod.provider, mod.id)
		if enabled_mod is not None:
			if is_version_newer(enabled_mod.version, mod.version):
				if force:
					logging.info('Force installing older version of mod because --force was requested')
					self.remove_mod_files(enabled_mod)
				else:
					logging.error('Mod %s is already installed' % mod.name)
					return True
			else:
				# Remove old version of this mod
				self.remove_mod_files(enabled_mod)

		logging.info('Ensuring %s is downloaded' % mod.package)
		mod.download()
		mod.calculate_files()

		if self.check_mod_files_installed(mod, 'any'):
			if force:
				logging.info('Mod will overwrite existing files!')
			else:
				logging.error('Mod %s will overwrite existing files. Aborting.' % mod.name)
				return False

		# Copy the package into the game executable directory.
		self.install_mod_files(mod)

		# Save the newly installed mod back to the registry
		mod.register()

		# Record a note of this mod and the version installed.
		utils.makedirs(os.path.join(self.get_app_directory(), '.mods'))
		with open(os.path.join(self.get_app_directory(), '.mods', mod.id), 'w') as f:
			f.write(mod.version)
		utils.ensure_file_ownership(os.path.join(self.get_app_directory(), '.mods', mod.id))

		# Handle all dependencies for this mod
		self.install_mod_dependencies(mod)

		return True

	def remove_mod(self, mod: 'GameMod') -> bool:
		"""
		Remove a mod

		Will completely uninstall the requested mod

		:param mod:
		:return:
		"""

		# Uninstall the files from this mod
		self.remove_mod_files(mod)

		# Remove the registration file for this mod
		if os.path.exists(os.path.join(self.get_app_directory(), '.mods', mod.id)):
			logging.info('Removing registration file for mod %s' % mod.name)
			os.remove(os.path.join(self.get_app_directory(), '.mods', mod.id))

		return True


	def is_api_enabled(self) -> bool:
		"""
		Check if API is enabled for this service
		:return:
		"""
		return False

	def get_player_max(self) -> int:
		"""
		Get the maximum player count allowed on the server
		:return:
		"""
		return 10

	def get_name(self) -> str:
		"""
		Get the name of this game server instance
		:return:
		"""
		return self.get_option_value('Server Name')

	def get_port(self) -> int | None:
		"""
		Get the primary port of the service, or None if not applicable
		:return:
		"""
		return self.get_option_value('Game Port')

	def get_game_pid(self) -> int:
		"""
		Get the primary game process PID of the actual game server, or 0 if not running
		:return:
		"""

		# For services that do not have a helper wrapper, it's the same as the process PID
		return self.get_pid()

	def get_port_definitions(self) -> list:
		"""
		Get a list of port definitions for this service
		:return:
		"""
		return [
			('Game Port', 'udp', '%s game port' % self.game.name),
			(self.get_option_value('Game Port')+1, 'udp', '%s query port' % self.game.name)
		]


if __name__ == '__main__':
	app = app_runner(GameApp())
	app()
