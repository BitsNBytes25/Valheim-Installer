#!/usr/bin/env python3
import logging
import os
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
from warlock_manager.services.base_service import BaseService
from warlock_manager.config.ini_config import INIConfig
from warlock_manager.libs.app_runner import app_runner
from warlock_manager.libs.firewall import Firewall
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

		# @todo Support for BepinEx:
		'''
		DOORSTOP_ENABLED=1
		DOORSTOP_TARGET_ASSEMBLY=$GAME_DIR/AppFiles/BepInEx/core/BepInEx.Preloader.dll
		LD_PRELOAD=$GAME_DIR/AppFiles/doorstop_libs/libdoorstop_x64.so
		LD_LIBRARY_PATH=$GAME_DIR/AppFiles/linux64:$GAME_DIR/AppFiles/doorstop_libs
		'''
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

		# Reload systemd to apply changes
		self.build_systemd_config()
		self.reload()

	def create_service(self):
		"""
		Create the systemd service for this game, including the service file and environment file
		:return:
		"""

		# Ensure some required parameters are set
		if not self.option_has_value('Server Name'):
			self.set_option('Server Name', self.service)
		if not self.option_has_value('World Name'):
			self.set_option('World Name', self.service)
		self.option_ensure_set('Join Password')

		super().create_service()

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
