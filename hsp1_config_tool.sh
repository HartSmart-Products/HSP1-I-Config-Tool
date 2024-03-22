#!/bin/bash

# Exit if any step fails
set -e

# Config values
USTREAMER_DEPENDENCIES=(libevent-dev libjpeg9-dev libbsd-dev libasound2-dev libspeex-dev libspeexdsp-dev libopus-dev)
ONBOARD_DEPENDENCIES=(at-spi2-core gir1.2-atspi-2.0 onboard rpi-chromium-mods)

PKG_MANAGER="apt-get"
# A variable to store the command used to update the package cache
UPDATE_PKG_CACHE="${PKG_MANAGER} update"
# The command we will use to actually install packages
PKG_INSTALL=("${PKG_MANAGER}" -qq install)
# grep -c will return 1 if there are no matches. This is an acceptable condition, so we OR TRUE to prevent set -e exiting the script.
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"

# Repo URLs/Locations
CONFIG_GIT_URL="https://github.com/HartSmart-Products/HSP1-I-SD-Image.git"
USTREAMER_GIT_URL="https://github.com/pikvm/ustreamer.git"
REPO_TEMP_DIR="/home/pi/.hsp/temp/repos"
TOOL_GIT_DIRECTORY="${REPO_TEMP_DIR}/hsp1-i-config-tool"

# Install Locations
CONFIG_DIR="/opt/dsf/sd"
AUTOSTART_DIR="/home/pi/.config/autostart"

# If the color table file exists,
if [[ -f "${coltable}" ]]; then
    # source it
    source "${coltable}"
# Otherwise,
else
    # Set these values so the installer can still run in color
    COL_NC='\e[0m' # No Color
    COL_LIGHT_GREEN='\e[1;32m'
    COL_LIGHT_RED='\e[1;31m'
    TICK="[${COL_LIGHT_GREEN}✓${COL_NC}]"
    CROSS="[${COL_LIGHT_RED}✗${COL_NC}]"
    INFO="[i]"
    # shellcheck disable=SC2034
    DONE="${COL_LIGHT_GREEN} done!${COL_NC}"
    OVER="\\r\\033[K"
fi

update_hostname=false
set_dpi=false
disable_bluetooth=false
update_config=false
install_ustreamer=false
install_onboard=false
print_help=false

for var in "$@"; do
    case "$var" in
        "--update" | "-u" ) update_config=true;;
        "--print-cam" ) install_ustreamer=true;;
        "--keyboard" ) install_onboard=true;;
        "--help" | "-h" ) print_help=true;;
        "--all" | "-a" )
            update_config=true
            install_ustreamer=true
            install_onboard=true
            disable_bluetooth=true
            update_hostname=true
            set_dpi=true
            ;;
    esac
done

is_command() {
    # Checks for existence of string passed in as only function argument.
    # Exit value of 0 when exists, 1 if not exists. Value is the result
    # of the `command` shell built-in call.
    local check_command="$1"

    command -v "${check_command}" >/dev/null 2>&1
}

# A function for checking if a directory is a git repository
is_repo() {
    # Use a named, local variable instead of the vague $1, which is the first argument passed to this function
    # These local variables should always be lowercase
    local directory="${1}"
    # A variable to store the return code
    local rc
    # If the first argument passed to this function is a directory,
    if [[ -d "${directory}" ]]; then
        # move into the directory
        pushd "${directory}" &> /dev/null || return 1
        # Use git to check if the directory is a repo
        # git -C is not used here to support git versions older than 1.8.4
        git status --short &> /dev/null || rc=$?
    # If the command was not successful,
    else
        # Set a non-zero return code if directory does not exist
        rc=1
    fi
    # Move back into the directory the user started in
    popd &> /dev/null || return 1
    # Return the code; if one is not set, return 0
    return "${rc:-0}"
}

# A function to clone a repo
make_repo() {
    # Set named variables for better readability
    local directory="${1}"
    local remoteRepo="${2}"

    # The message to display when this function is running
    str="Clone ${remoteRepo} into ${directory}"
    # Display the message and use the color table to preface the message with an "info" indicator
    printf "  %b %s..." "${INFO}" "${str}"
    # If the directory exists,
    if [[ -d "${directory}" ]]; then
        # Return with a 1 to exit the installer. We don't want to overwrite what could already be here in case it is not ours
        str="Unable to clone ${remoteRepo} into ${directory} : Directory already exists"
        printf "%b  %b%s\\n" "${OVER}" "${CROSS}" "${str}"
        return 1
    fi
    # Clone the repo and return the return code from this command
    git clone -q --depth 20 "${remoteRepo}" "${directory}" &> /dev/null || return $?
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Show a colored message showing it's status
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

# We need to make sure the repos are up-to-date so we can effectively install Clean out the directory if it exists for git to clone into
update_repo() {
    # Use named, local variables
    # As you can see, these are the same variable names used in the last function,
    # but since they are local, their scope does not go beyond this function
    # This helps prevent the wrong value from being assigned if you were to set the variable as a GLOBAL one
    local directory="${1}"

    # A variable to store the message we want to display;
    # Again, it's useful to store these in variables in case we need to reuse or change the message;
    # we only need to make one change here
    local str="Update repo in ${1}"
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Let the user know what's happening
    printf "  %b %s..." "${INFO}" "${str}"
    # Stash any local commits as they conflict with our working code
    git stash --all --quiet &> /dev/null || true # Okay for stash failure
    git clean --quiet --force -d || true # Okay for already clean directory
    # Pull the latest commits
    git pull --no-rebase --quiet &> /dev/null || return $?
    # Show a completion message
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

rebase_repo() {
    # Setup named variables for the git repos
    # We need the directory
    local directory="${1}"
    # A variable to store the message we want to display;
    local str="Update repo in ${1}"
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Let the user know what's happening
    printf "  %b %s..." "${INFO}" "${str}"
    # Pull the latest commits
    git pull --rebase --autostash --quiet &> /dev/null || return $?
    # Show a completion message
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

# A function that combines the previous git functions to update or clone a repo
getGitFiles() {
    # Setup named variables for the git repos
    # We need the directory
    local directory="${1}"
    # as well as the repo URL
    local remoteRepo="${2}"
    # A local variable containing the message to be displayed
    local str="Check for existing repository in ${1}"
    # Show the message
    printf "  %b %s..." "${INFO}" "${str}"
    # Check if the directory is a repository
    if is_repo "${directory}"; then
        # Show that we're checking it
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
        # Update the repo, returning an error message on failure
        update_repo "${directory}" || { printf "\\n  %b: Could not update local repository. Contact support.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    # If it's not a .git repo,
    else
        # Show an error
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        # Attempt to make the repository, showing an error on failure
        make_repo "${directory}" "${remoteRepo}" || { printf "\\n  %bError: Could not update local repository. Contact support.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    fi
    echo ""
    # Success via one of the two branches, as the commands would exit if they failed.
    return 0
}

# Reset a repo to get rid of any local changed
resetRepo() {
    # Use named variables for arguments
    local directory="${1}"
    # Move into the directory
    pushd "${directory}" &> /dev/null || return 1
    # Store the message in a variable
    str="Resetting repository within ${1}..."
    # Show the message
    printf "  %b %s..." "${INFO}" "${str}"
    # Use git to remove the local changes
    git reset --hard &> /dev/null || return $?
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # And show the status
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Return to where we came from
    popd &> /dev/null || return 1
    # Function succeeded, as "git reset" would have triggered a return earlier if it failed
    return 0
}


test_dpkg_lock() {
    i=0
    printf "  %b Waiting for package manager to finish (up to 30 seconds)\\n" "${INFO}"
    # fuser is a program to show which processes use the named files, sockets, or filesystems
    # So while the lock is held,
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1
    do
        # we wait half a second,
        sleep 0.5
        # increase the iterator,
        ((i=i+1))
        # exit if waiting for more then 30 seconds
        if [[ $i -gt 60 ]]; then
            printf "  %b %bError: Could not verify package manager finished and released lock. %b\\n" "${CROSS}" "${COL_LIGHT_RED}" "${COL_NC}"
            printf "       Attempt to install packages manually and retry.\\n"
            exit 1;
        fi
    done
    # and then report success once dpkg is unlocked.
    return 0
}

update_package_cache() {
    # Local, named variables
    local str="Update local cache of available packages"
    printf "  %b %s..." "${INFO}" "${str}"
    # Create a command from the package cache variable
    if eval "${UPDATE_PKG_CACHE}" &> /dev/null; then
        printf "%b  %b %s\\n\\n" "${OVER}" "${TICK}" "${str}"
    else
        # Otherwise, show an error and exit

        # In case we used apt-get and apt is also available, tell the user to use apt
        if [[ ${PKG_MANAGER} == "apt-get" ]] && is_command apt ; then
            UPDATE_PKG_CACHE="apt update"
        fi
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        printf "  %b Error: Unable to update package cache. Please try \"%s\"%b\\n" "${COL_LIGHT_RED}" "sudo ${UPDATE_PKG_CACHE}" "${COL_NC}"
        return 1
    fi
}

install_dependencies() {
    declare -a installArray

    if is_command apt-get ; then
        # For each package, check if it's already installed (and if so, don't add it to the installArray)
        for i in "$@"; do
            printf "  %b Checking for %s..." "${INFO}" "${i}"
            if dpkg-query -W -f='${Status}' "${i}" 2>/dev/null | grep "ok installed" &> /dev/null; then
                printf "%b  %b Checking for %s\\n" "${OVER}" "${TICK}" "${i}"
            else
                printf "%b  %b Checking for %s (will be installed)\\n" "${OVER}" "${INFO}" "${i}"
                installArray+=("${i}")
            fi
        done
        # If there's anything to install, install everything in the list.
        if [[ "${#installArray[@]}" -gt 0 ]]; then
            test_dpkg_lock
            # Running apt-get install with minimal output can cause some issues with
            # requiring user input
            printf "  %b Processing %s install(s) for: %s, please wait...\\n" "${INFO}" "${PKG_MANAGER}" "${installArray[*]}"
            printf '%*s\n' "${c}" '' | tr " " -;
            "${PKG_INSTALL[@]}" "${installArray[@]}"
            printf '%*s\n' "${c}" '' | tr " " -;
            return
        fi
        printf "\\n"
        return 0
    fi
}

stop_service() {
    # Stop service passed in as argument.
    # Can softfail, as process may not be installed when this is called
    local str="Stopping ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    if is_command systemctl ; then
        systemctl stop "${1}" &> /dev/null || true
    else
        service "${1}" stop &> /dev/null || true
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Start/Restart service passed in as argument
restart_service() {
    # Local, named variables
    local str="Restarting ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to restart the service
        systemctl restart "${1}" &> /dev/null
    else
        # Otherwise, fall back to the service command
        service "${1}" restart &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Enable service so that it will start with next reboot
enable_service() {
    # Local, named variables
    local str="Enabling ${1} service to start on reboot"
    printf "  %b %s..." "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to enable the service
        systemctl enable "${1}" &> /dev/null
    else
        #  Otherwise, use update-rc.d to accomplish this
        update-rc.d "${1}" defaults &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Disable service so that it will not with next reboot
disable_service() {
    # Local, named variables
    local str="Disabling ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to disable the service
        systemctl disable "${1}" &> /dev/null
    else
        # Otherwise, use update-rc.d to accomplish this
        update-rc.d "${1}" disable &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

check_service_active() {
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to check the status of the service
        systemctl is-enabled "${1}" &> /dev/null
    else
        # Otherwise, fall back to service command
        service "${1}" status &> /dev/null
    fi
}

install_config() {
	if is_repo ${CONFIG_DIR}; then
		printf "  %b Updating config..." "${INFO}"
		
		rebase_repo ${CONFIG_DIR} ${CONFIG_GIT_URL}
		
		printf "%b  %b Updating config\\n" "${OVER}" "${TICK}"
	else
		printf "  %b Installing config..." "${INFO}"
		
		rm -rf $CONFIG_DIR &> /dev/null
		
		getGitFiles ${CONFIG_DIR} ${CONFIG_GIT_URL}
		
		mkdir "${CONFIG_DIR}/gcodes"
		mkdir "${CONFIG_DIR}/firmware"
		ln -s /opt/dsf/dwc "${CONFIG_DIR}/www"
		
		chown dsf:dsf -R -f ${CONFIG_DIR}
		
		sudo -u pi git config --global --add safe.directory "${CONFIG_DIR}"
		
		printf "%b  %b Installing config\\n" "${OVER}" "${TICK}"

        return 0
	fi
}

build_install_ustreamer() {
    printf "  %b Compiling ustreamer..." "${INFO}"

    pushd "${REPO_TEMP_DIR}/ustreamer" &> /dev/null || return 1

    make clean &> /dev/null || return $?

    make &> /dev/null || return $?

    make install &> /dev/null || return $?

    printf "%b  %b Compiling ustreamer\\n" "${OVER}" "${TICK}"

    popd &> /dev/null || return 1

    return 0
}

ustreamer_service() {
    printf "  %b Creating ustreamer service..." "${INFO}"

    if id ustreamer >/dev/null 2>&1; then
        if !(id -nG ustreamer | grep -qw "video"); then
            sudo usermod -a -G video ustreamer
        fi
    else
        sudo useradd -r ustreamer
        sudo usermod -a -G video ustreamer
    fi

    install -T -m 0644 "${TOOL_GIT_DIRECTORY}/ustreamer.service" '/etc/systemd/system/ustreamer.service'

    if [[ -e '/etc/init.d/ustreamer' ]]; then
        rm '/etc/init.d/ustreamer'
        update-rc.d ustreamer remove
    fi

    systemctl daemon-reload

    enable_service ustreamer

    stop_service ustreamer &> /dev/null

    restart_service ustreamer

    printf "%b  %b Creating ustreamer service\\n" "${OVER}" "${TICK}"
}

enable_gdi_accessibility() {
    # May want to reboot after this, check if it's set and advise the user
    if [[ $(gsettings get org.gnome.desktop.interface toolkit-accessibility) == "false" ]]; then
        sudo -u pi gsettings set org.gnome.desktop.interface toolkit-accessibility true
        printf "%b  %b Configured gnome accessibility\\n" "${OVER}" "${TICK}"
    fi
}

onboard_config() {
    printf "  %b Installing onboard configs..." "${INFO}"

    mkdir -p ${AUTOSTART_DIR}

    install -T -m 0644 "${TOOL_GIT_DIRECTORY}/onboard-defaults.conf" '/usr/share/onboard/onboard-defaults.conf'

    install -T -m 0755 "${TOOL_GIT_DIRECTORY}/onboard.desktop" "${AUTOSTART_DIR}/onboard.desktop"

    printf "%b  %b Installing onboard configs\\n" "${OVER}" "${TICK}"
}

update_hostname() {
    printf "  %b Updating Hostname..." "${INFO}"

    if [[ $(hostname -s) = 'pi' ]]; then
        hostnamectl set-hostname 'HSP1-I' &> /dev/null
        printf "%b  %b Updating Hostname\\n" "${OVER}" "${TICK}"

        return 0
    fi

    printf "%b  %b Hostname already set\\n" "${OVER}" "${INFO}"
}

set_dpi() {
    printf "  %b Setting DPI..." "${INFO}"

    if ! [ -f '/home/pi/.Xresources' ]; then
        install -T -m 0644 "${TOOL_GIT_DIRECTORY}/.Xresources" '/home/pi/.Xresources'
        printf "%b  %b Setting DPI\\n" "${OVER}" "${TICK}"

        return 0
    fi

    printf "%b  %b DPI already set\\n" "${OVER}" "${INFO}"
}

disable_bluetooth() {
    printf "  %b Disabling Bluetooth..." "${INFO}"

    if ! grep -Fxq "# Disable Bluetooth" '/boot/config.txt'; then
        echo -e "# Disable Bluetooth\ndtoverlay=disable-bt\n" >> '/boot/config.txt'

        systemctl disable hciuart.service &> /dev/null

        systemctl disable bluetooth.service &> /dev/null
    fi

    printf "%b  %b Disabling Bluetooth\\n" "${OVER}" "${TICK}"
}


main() {
    if [[ "${print_help}" = true ]]; then
        # Only print help and then exit
        help_text="---------------------------------------------------------------
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
---------------------------------------------------------------\n"
        printf "%b" "${help_text}"
    else
        local str="Root user check"
        printf "\\n"

        if [[ "${EUID}" -eq 0 ]]; then
            # Running with sudo, continue
            printf "  %b %s\\n" "${TICK}" "${str}"
        else
            if is_command sudo ; then
                exec sudo bash "$0" "$@"
            else
                # Otherwise, tell the user they need to run the script as root, and bail
                printf "  %b Sudo is needed to install dependencies\\n\\n" "${INFO}"
                printf "  %b %bPlease re-run this as root${COL_NC}\\n" "${INFO}" "${COL_LIGHT_RED}"
                exit 1
          fi
        fi

        printf "HSP1-I Config Tool\\n\\n"

        # Do everything else
        if $update_hostname; then
            update_hostname
        fi

        if $set_dpi; then
            set_dpi
        fi

        if $disable_bluetooth; then
            disable_bluetooth
        fi

        if $update_config; then
            printf "Updating Config\\n"
            install_config
        fi

        if $install_ustreamer || $install_onboard; then
            update_package_cache
        fi

        if $install_ustreamer; then
            printf "Installing Webcam Service\\n"
            install_dependencies "${USTREAMER_DEPENDENCIES[@]}"
            getGitFiles "${REPO_TEMP_DIR}/ustreamer" ${USTREAMER_GIT_URL}
            build_install_ustreamer
            ustreamer_service
        fi

        if $install_onboard; then
            printf "Installing On-screen Keyboard\\n"
            install_dependencies "${ONBOARD_DEPENDENCIES[@]}"
            enable_gdi_accessibility
            onboard_config
        fi
    fi
}

main "$@"
