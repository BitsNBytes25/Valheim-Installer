# Using this boilerplate template

Clone this repo and start populating with your game.

## Directory Structure

The notable directories are:

### `src/`

Contains the scripts which will get compiled.
Refer to [Scripts Collection Builder by eVAL](https://github.com/eVAL-Agency/ScriptsCollection) for documentation
on using the compiler and what inline flags are supported.

In short, it just glues together a bunch of scripts into a single, distributable file.

To make changes to your installer, **do so in src/!**.

### `scripts/`

Not to be confused with src, this directory contains supplemental files used by scripts within src.
These do not get compiled, but are instead referenced by the scripts in src.

* configs.yaml - A YAML file containing configuration data for your game.
* systemd-template.service - A systemd service template file for running your game as a service.

### `media/`

Contains media assets for your game, such as images, audio files, etc.
It is recommended to provide at least a small logo, medium size thumbnail, and full size teaser image.

### `dist/`

This directory will contain the compiled output of your game installer.
By default this will contain `installer.sh`, `manage.py`, `community_scripts.json`, and `warlock.yaml`.

* The installer is the primary end point for installing the library.
* The manager is a utility script for managing the installed game and interfacing with [Warlock](https://github.com/BitsNBytes25/Warlock).
* community_scripts.json is a manifest file for [Tactical RMM](https://github.com/amidaware/tacticalrmm) (not generally used here)
* warlock.yaml is a configuration file for Warlock.


## Building your Installer

Once you have populated the `src/` directory with your scripts, you can build your installer by running:

```bash
./compile.py
```


## Deploying to Warlock

To deploy your game to Warlock, copy the contents of warlock.yaml
and add it to `Apps.yaml` in Warlock.

For local testing, just updating your local copy is sufficient,
but to publish your installer to the greater community please issue a merge request
with your metadata.


## Supplemental Projects and Shameless-self-plugs

* [Scripts Collection Builder by eVAL](https://github.com/eVAL-Agency/ScriptsCollection)
* [Warlock by BitsNBytes25](https://github.com/BitsNBytes25/Warlock)
* [Bits n Bytes Community](https://bitsnbytes.dev)
* [Donate to this project](https://ko-fi.com/bitsandbytes)
* [Join our Discord](https://discord.gg/jyFsweECPb)
* [Follow us on Mastodon](https://social.bitsnbytes.dev/@sitenews)
