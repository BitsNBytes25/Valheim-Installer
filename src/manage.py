#!/usr/bin/env python3
import logging
import os
import zipfile

# To allow running as a standalone script without installing the package, include the venv path for imports.
# This will set the include path for this path to .venv to allow packages installed therein to be utilized.
#
# IMPORTANT - any imports that are needed for the script to run must be after this,
# otherwise the imports will fail when running as a standalone script.
# import:org_python/venv_path_include.py

# Import the appropriate type of handler for the game installer.
# Common options are:
# from warlock_manager.apps.base_app import BaseApp
from warlock_manager.apps.steam_app import SteamApp
from warlock_manager.formatters.cli_formatter import cli_formatter
from warlock_manager.libs.download import download_json, download_file

# Import the appropriate type of handler for the game services.
# Common options are:
from warlock_manager.services.base_service import BaseService
# from warlock_manager.services.rcon_service import RCONService
# from warlock_manager.services.socket_service import SocketService
# from warlock_manager.services.http_service import HTTPService

# Import the various configuration handlers used by this game.
# Common options are:
# from warlock_manager.config.cli_config import CLIConfig
from warlock_manager.config.ini_config import INIConfig
# from warlock_manager.config.json_config import JSONConfig
# from warlock_manager.config.properties_config import PropertiesConfig
# from warlock_manager.config.unreal_config import UnrealConfig

# Load the application runner responsible for interfacing with CLI arguments
# and providing default functionality for running the manager.
from warlock_manager.libs.app_runner import app_runner

# If your script manages the firewall, (recommended), import the Firewall library
from warlock_manager.libs.firewall import Firewall


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
		self.service_prefix = 'valheim-'

		self.disabled_features = {'api'}

		self.configs = {
			'manager': INIConfig('manager', os.path.join(self.get_app_directory(), '.settings.ini'))
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

	def get_mod(self, mod_id: str):
		data = download_json(self, 'https://thunderstore.io/c/valheim/api/v1/package/')
		for field in data:
			if field['uuid4'] == mod_id:
				return field
		return None


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
			'service': INIConfig('service', os.path.join(self.game.get_app_directory(), 'Configs', 'service.%s.ini' % self.service))
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
				'XDG_RUNTIME_DIR': '/run/user/%s' % self.game.get_app_uid(),
				'LD_PRELOAD': os.path.join(self.get_app_directory(), 'doorstop_libs', 'libdoorstop_x64.so'),
				'LD_LIBRARY_PATH': os.path.join(self.get_app_directory(), 'doorstop_libs') + ':' + os.path.join(self.get_app_directory(), 'linux64'),
				'SteamAppId': '892970',
				'DOORSTOP_ENABLED': '1',
				'DOORSTOP_TARGET_ASSEMBLY': os.path.join(self.get_app_directory(), 'BepInEx', 'core', 'BepInEx.Preloader.dll')
			}
		else:
			return {
				'XDG_RUNTIME_DIR': '/run/user/%s' % self.game.get_app_uid(),
				'LD_LIBRARY_PATH': os.path.join(self.get_app_directory(), 'linux64'),
				'SteamAppId': '892970'
			}

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
		return ['Worlds/%s.fwl' % self.get_option_value('World Name')]

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
			Firewall.allow(int(new_value), 'udp', '%s game port' % self.game.desc)
			Firewall.allow(int(new_value)+1, 'udp', '%s query port' % self.game.desc)
		elif option == 'Modded Instance':
			if new_value:
				# Install BepInEx
				self.add_mod('c11edf2c-85d9-42ff-811b-139faa4c51b3')
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

	def add_mod(self, mod_id: str, version: str = None):
		"""
		Install a mod on the server based on the mod UUID.

		This installs from Thunderstore.

		:param mod_id:
		:param version:
		:return:
		"""
		logging.debug('Installing mod %s' % mod_id)

		mod = self.game.get_mod(mod_id)
		if mod is None:
			logging.error('Mod not found: %s' % mod_id)
			return False
		else:
			logging.debug('Mod resolved to %s by %s' % (mod['name'], mod['owner']))

		version_data = None
		if version is not None:
			# Find the requested version.
			for v in mod['versions']:
				if v['version_number'] == version:
					version_data = v
					break
		else:
			# Latest version is generally the first entry.
			version_data = mod['versions'][0] if mod['versions'] and len(mod['versions']) > 0 else None

		if version_data is None:
			logging.error('Mod version not found: %s' % version)
			return False

		target_archive = os.path.join(self.game.get_app_directory(), 'Packages', version_data['full_name'] + '.zip')
		if not os.path.exists(target_archive):
			download_file(self.game, version_data['download_url'], target_archive)
		else:
			logging.debug('Mod already downloaded, skipping download')

		# Try to extract it in a way that makes sense
		logging.debug('Extracting mod to game directory')
		with zipfile.ZipFile(target_archive, 'r') as zip_ref:
			for member in zip_ref.namelist():
				if member in ['CHANGELOG.md', 'icon.png', 'manifest.json', 'README.md']:
					# Skip common non-essential files
					continue

				if member.startswith('plugins/'):
					# These can be extract directly, they're probably well formatted
					target_path = os.path.join(self.get_app_directory(), 'BepInEx', member)
				elif member.startswith('BepInExPack_Valheim/'):
					# These need to be pulled out of the directory they're in and should be in the root
					target_path = os.path.join(self.get_app_directory(), member.replace('BepInExPack_Valheim/', ''))
				else:
					# A number of developers just throw their DLLs in the root level of their zip
					target_path = os.path.join(self.get_app_directory(), 'BepInEx', 'plugins', member)

				logging.debug('Extracting %s -> %s' % (member, target_path))
				# Ensure the target directory exists
				self.game.ensure_file_parent_exists(target_path)
				if not member.endswith('/'):
					with zip_ref.open(member) as source, open(target_path, 'wb') as target:
						target.write(source.read())
					self.game.ensure_file_ownership(target_path)

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
			('Game Port', 'udp', '%s game port' % self.game.desc),
			(self.get_option_value('Game Port')+1, 'udp', '%s query port' % self.game.desc)
		]


if __name__ == '__main__':
	app = app_runner(GameApp())
	app()
