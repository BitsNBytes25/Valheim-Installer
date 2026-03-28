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
from warlock_manager.mods.base_mod import BaseMod
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


class GameMod(BaseMod):
	@classmethod
	def from_thunderstore(cls, data: dict, version: str | None) -> 'GameMod':
		"""
		Generate a Mod entry based on data from the Thunderstore API

		:param data:
		:param version:
		:return:
		"""
		if version is None or version == '' or version == 'latest':
			version_data = data['versions'][0] if data['versions'] and len(data['versions']) > 0 else None
		else:
			version_data = None
			for v in data['versions']:
				if v['version_number'] == version:
					version_data = v
					break

		mod = GameMod()
		mod.name = data['name']
		mod.id = data['uuid4']
		mod.author = data['owner']
		mod.url = data['package_url']
		if version_data is not None:
			if version_data['website_url']:
				mod.url = version_data['website_url']
			mod.source = version_data['download_url']
			mod.version = version_data['version_number']
			mod.package = version_data['full_name'] + '.zip'
			mod.icon = version_data['icon']
			mod.dependencies = version_data['dependencies']
			mod.description = version_data['description']

		return mod

	@classmethod
	def find_mods(cls, mod_lookup: str) -> list['BaseMod']:
		"""
		Search for a mod by its name, UUID, dependency string, or full URL from Thunderstore

		If a regular string is provided, it will search for a mod by its name.
		:param mod_lookup:
		:return:
		"""
		data = download_json('https://thunderstore.io/c/valheim/api/v1/package/')
		ret = []
		for field in data:
			if (
				field['uuid4'] == mod_lookup or
				field['package_url'] == mod_lookup or
				mod_lookup.startswith('%s-%s-' % (field['owner'], field['name']))
			):
				# Exact match found!
				if mod_lookup.startswith('%s-%s-' % (field['owner'], field['name'])):
					# Find the requested version
					version_check = mod_lookup.replace('%s-%s-' % (field['owner'], field['name']), '')
					mod = GameMod.from_thunderstore(field, version_check)
				else:
					mod = GameMod.from_thunderstore(field, None)
				return [mod]

			elif mod_lookup.lower() in field['name'].lower():
				mod = GameMod.from_thunderstore(field, None)
				ret.append(mod)

		return ret


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
			logging.info('Detected %d services, skipping first-run service creation.' % len(services))
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
		return ['%s.fwl' % self.get_option_value('World Name')]

	def option_value_updated(self, option: str, previous_value, new_value):
		"""
		Handle any special actions needed when an option value is updated
		:param option:
		:param previous_value:
		:param new_value:
		:return:
		"""

		# Special option actions
		if option == 'Game Port':
			# Update firewall for game port change
			if previous_value:
				Firewall.remove(int(previous_value), 'udp')
				Firewall.remove(int(previous_value)+1, 'udp')
			Firewall.allow(int(new_value), 'udp', '%s game port' % self.game.name)
			Firewall.allow(int(new_value)+1, 'udp', '%s query port' % self.game.name)
		elif option == 'Modded Instance':
			if new_value:
				# Install BepInEx
				mods = GameMod.find_mods('https://thunderstore.io/c/valheim/p/denikson/BepInExPack_Valheim/')
				if len(mods) > 0:
					self.add_mod(mods[0])
			# Regenerate the environmental file
			with open(self._env_file, 'w') as f:
				env = self.get_environment()
				for key in env:
					f.write('%s=%s\n' % (key, env[key]))

		# Reload systemd to apply changes
		self.build_systemd_config()
		self.reload()

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

		:return:
		"""
		mods = GameMod.get_registered_mods()
		enabled_mods = []
		for mod in mods:
			if os.path.join(self.get_app_directory(), '.mods', mod.id):
				with open(os.path.join(self.get_app_directory(), '.mods', mod.id), 'r') as f:
					if f.read() == mod.version:
						enabled_mods.append(mod)
		return enabled_mods

	def add_mod(self, mod: 'BaseMod') -> bool:
		"""
		Install a mod

		:param mod:
		:return:
		"""
		logging.info('Installing mod %s' % mod.name)
		# Check if this mod is already installed.
		installed_mods = self.get_enabled_mods()
		for installed_mod in installed_mods:
			if installed_mod.id == mod.id:
				if not is_version_newer(installed_mod.version, mod.version):
					logging.error('Mod %s is already installed' % mod.name)
					return True
				else:
					break

		logging.info('Ensuring %s is downloaded' % mod.package)
		mod.download()

		# Try to extract it in a way that makes sense
		logging.info('Extracting mod to game directory')
		mod.files = []
		target_archive = os.path.join(utils.get_app_directory(), 'Packages', mod.package)
		with zipfile.ZipFile(target_archive, 'r') as zip_ref:
			for member in zip_ref.namelist():
				if member in ['CHANGELOG.md', 'icon.png', 'manifest.json', 'README.md']:
					# Skip common non-essential files
					continue

				if member.startswith('plugins/'):
					# These can be extract directly, they're probably well formatted
					target_path = os.path.join('BepInEx', member)
				elif member.startswith('BepInExPack_Valheim/'):
					# These need to be pulled out of the directory they're in and should be in the root
					target_path = member.replace('BepInExPack_Valheim/', '')
				else:
					# A number of developers just throw their DLLs in the root level of their zip
					target_path = os.path.join('BepInEx', 'plugins', member)

				logging.debug('Extracting %s -> %s' % (member, target_path))
				mod.files.append(target_path)
				target_path_full = os.path.join(self.get_app_directory(), target_path)
				# Ensure the target directory exists
				utils.ensure_file_parent_exists(target_path_full)
				if member.endswith('/'):
					# Directory, create it
					utils.makedirs(target_path_full)
				else:
					# File, extract it
					with zip_ref.open(member) as source, open(target_path_full, 'wb') as target:
						target.write(source.read())
					utils.ensure_file_ownership(target_path_full)

		# Save the newly installed mod back to the registry
		mod.register()

		# Record a note of this mod and the version installed.
		utils.makedirs(os.path.join(self.get_app_directory(), '.mods'))
		with open(os.path.join(self.get_app_directory(), '.mods', mod.id), 'w') as f:
			f.write(mod.version)
		utils.ensure_file_ownership(os.path.join(self.get_app_directory(), '.mods', mod.id))

		# Handle all dependencies for this mod
		for dep in mod.dependencies:
			logging.info('Handling dependency %s for mod %s' % (dep, mod.name))
			if not self.add_mod(dep):
				logging.error('Failed to install dependency %s for mod %s' % (dep, mod.name))

		return True

	def remove_mod(self, mod: 'BaseMod') -> bool:
		"""
		Remove a mod

		Will completely uninstall the requested mod

		:param mod:
		:return:
		"""
		# Uninstall the files from this mod
		for file in mod.files:
			target_path_full = os.path.join(self.get_app_directory(), file)
			if os.path.isdir(target_path_full):
				logging.info('Removing directory %s' % file)
				shutil.rmtree(target_path_full)
			elif os.path.isfile(target_path_full):
				logging.info('Removing file %s' % file)
				os.remove(target_path_full)
			else:
				logging.debug('Skipping non-present file %s' % file)

		# Remove the registration file for this mod
		if os.path.exists(os.path.join(self.get_app_directory(), '.mods', mod.id)):
			logging.info('Removing registration file for mod %s' % mod.name)
			os.remove(os.path.join(self.get_app_directory(), '.mods', mod.id))

		# Also scan for any dependencies for this mod, they must be removed too.
		# The depdendency name is just the zip name of the package, sans .zip
		enabled_mods = self.get_enabled_mods()
		this_dep = mod.package[:-4]
		for enabled_mod in enabled_mods:
			if enabled_mod == mod:
				# Skip this mod
				continue
			for dep in enabled_mod.dependencies:
				if dep == this_dep:
					logging.info('Also removing dependent mod %s' % enabled_mod.name)
					self.remove_mod(enabled_mod)
					break

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
