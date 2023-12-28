# HSP1-I Config Tool

## Usage

### Initial setup
Run `curl -sSL https://github.com/HartSmart-Products/HSP1-I-Config-Tool/raw/main/hsp1_config_tool.sh -a | bash`

### Command Options
```
---------------------------------------------------------------
The following parameters can be passed to this script:

[-a | --all ].........: Do everything. Installs/updates the 
                        configuration, and installs support
                        components.
[-h | --help ]........: Outputs a help dialog with options.
[-u | --update ]......: Updates the config files. Won't
                        overwrite machine-specific files.
[--keyboard ].........: Installs the onscreen keyboard and
                        configuration files.
[--print-cam ]........: Installs the camera streamer software
                        and configures the streamer service
                        and camera configuration.
---------------------------------------------------------------
```