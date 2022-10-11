has_package() {
    pacman -Qq "${1}" > /dev/null 2>&1
}

has_older_package() {
    local PACKAGE_INFO

    # Check is the package installed
    PACKAGE_INFO=$(pacman -Q "${1}" 2> /dev/null)
    [[ $? = 1 ]] && return 1

    # Check is an older version installed
    [[ "$(vercmp "$(echo "${PACKAGE_INFO}" | cut -d ' ' -f 2)" "${2}")" -lt 0 ]]
}

db_unlock() {
    local DB_LOCK="$(pacman-conf DBPath)db.lck"

    # Remove the database lock only if it's actually present;  of course,
    # it does smell like a TOCTOU issue, but that doesn't matter anyway
    if [[ -f "${DB_LOCK}" ]]; then
        echo "    Unlocking pacman database..."
        rm -f "${DB_LOCK}"
    fi
}

enable_fstrim() {
    systemctl status fstrim.timer > /dev/null 2>&1

    # Enable the timer only if found and not already enabled
    if [[ $? = 3 ]]; then
        echo "==> Enabling periodic trimming of filesystems..."
        systemctl enable $1 --quiet fstrim.timer

        # Optionally, start the associated service once manually
        if [[ "$1" == "--now" ]]; then
            echo "    Starting initial filesystem trimming in background..."
            systemctl start fstrim.service
        fi
    fi
}

post_install() {
    # Ensure enabled fstrim timer from util-linux package
    enable_fstrim
}

post_upgrade() {
    # Remove Calamares autostart files if Calamares isn't installed
    if ! has_package "calamares"; then
        local HOME_PATH HOME_PATHS
        local DESKTOP_FILE DESKTOP_FILES
        local IFS_DEFAULT CONSOLE_NOTIFIED

        HOME_PATHS=$(cat /etc/passwd | gawk --field-separator ':' '{ if ($3 >= 1000 && $3 < 65534) print "\"" $6 "\"" }')
        if [[ ! -z ${HOME_PATHS} ]]; then
            # Handle spaces in file paths properly
            IFS_DEFAULT="${IFS}"
            IFS=$'\n'

            # There could be many users, so loop through them one by one
            for HOME_PATH in ${HOME_PATHS}; do
                DESKTOP_FILES=$(compgen -G "${HOME_PATH//\"/}/.config/autostart/calamares.desktop")
                if [[ ! -z ${DESKTOP_FILES} ]]; then
                    CONSOLE_NOTIFIED=false
                    for DESKTOP_FILE in ${DESKTOP_FILES}; do
                        if [[ "${CONSOLE_NOTIFIED}" = false ]]; then
                            echo "==> Removing redundant Calamares autostart file..."
                            CONSOLE_NOTIFIED=true
                        fi
                        rm -f "${DESKTOP_FILE}"
                    done
                fi
            done

            # Restore the default output splitting
            IFS="${IFS_DEFAULT}"
        fi
    fi

    # Ensure installed xfce4-screensaver to match changes in the Xfce
    # edition profile, which makes screen locking work on Xfce installs
    if has_package "xfwm4" && \
       has_package "xfce4-panel" && \
       ! has_package "xfce4-screensaver"; then
        echo "==> Installing 'xfce4-screensaver' to enable screen locking..."
        db_unlock
        pacman -S xfce4-screensaver --noconfirm
    fi

    # Ensure enabled fstrim timer from util-linux package, and start
    # the timer if it wasn't found to be already enabled
    enable_fstrim --now

    # Ensure updated signing keys for the Manjaro team members
    local EXPIRED_KEY EXPIRED_KEYS
    local CONSOLE_NOTIFIED=false

    EXPIRED_KEYS=(
       "1BF79786E554EF5D"    # Furkan Kardame
       "1F358118A07ACF57"    # Ray Sherwin
    )
    for EXPIRED_KEY in ${EXPIRED_KEYS[@]}; do
        pacman-key --list-keys "${EXPIRED_KEY}" 2> /dev/null | grep -q 'expired'
        if [[ $? = 0 ]]; then
            if [[ "${CONSOLE_NOTIFIED}" = false ]]; then
                echo "==> Refreshing package signing keys..."
                CONSOLE_NOTIFIED=true
            fi
            pacman-key --refresh-key "${EXPIRED_KEY}"
        fi
    done

    # Switch the remaining bits for the new Plasma theme
    if [ -f /etc/sddm.conf.d/kde_settings.conf ] && \
       grep -q 'Current=breath2' /etc/sddm.conf.d/kde_settings.conf; then
        echo "==> Updating Plasma theme system settings..."
        sed -i -e 's/Current=breath2/Current=breath/g' /etc/sddm.conf.d/kde_settings.conf
    fi

    # Plasma theme changes continued...
    if [ -f /etc/xdg/kscreenlockerrc ] && \
       grep -q -F 'Image=file:///usr/share/wallpapers/Breath2/contents/images/1920x1080.png' /etc/xdg/kscreenlockerrc; then
        echo "==> Updating Plasma screen locker settings..."
        sed -i -e 's@Image=file:///usr/share/wallpapers/Breath2/contents/images/1920x1080.png@Image=/usr/share/wallpapers/Bamboo/@g' \
            /etc/xdg/kscreenlockerrc
    fi

    # Plasma theme changes continued, last part
    if has_package "konsole"; then
        local HOME_PATH HOME_PATHS
        local PROFILE_FILE PROFILE_FILES
        local IFS_DEFAULT CONSOLE_NOTIFIED

        HOME_PATHS=$(cat /etc/passwd | gawk --field-separator ':' '{ if ($3 >= 1000 && $3 < 65534) print "\"" $6 "\"" }')
        if [[ ! -z ${HOME_PATHS} ]]; then
            # Handle spaces in file paths properly
            IFS_DEFAULT="${IFS}"
            IFS=$'\n'

            # There could be many users, so loop through them one by one
            for HOME_PATH in ${HOME_PATHS}; do
                PROFILE_FILES=$(compgen -G "${HOME_PATH//\"/}/.local/share/konsole/*.profile")
                if [[ ! -z ${PROFILE_FILES} ]]; then
                    CONSOLE_NOTIFIED=false
                    for PROFILE_FILE in ${PROFILE_FILES}; do
                        if grep -q 'ColorScheme=Breath2' "${PROFILE_FILE}"; then
                            if [[ "${CONSOLE_NOTIFIED}" = false ]]; then
                                echo "==> Updating Plasma theme user settings..."
                                CONSOLE_NOTIFIED=true
                            fi
                            sed -i -e 's/ColorScheme=Breath2/ColorScheme=Breath/g' "${PROFILE_FILE}"
                        fi
                    done
                fi
            done

            # Restore the default output splitting
            IFS="${IFS_DEFAULT}"
        fi
    fi

    # Uninstall TLP because it provides no benefits, hogs the CPU, and even causes issues,
    # e.g. kernel panics with SATA drives off a PCI Express SATA card in a RockPro64
    if has_package "tlp"; then
        echo "==> Uninstalling redundant 'tlp' package..."
        db_unlock
        systemctl disable --now --quiet tlp
        pacman -R tlp --noconfirm
    fi

    # Plasma Mobile has switched to ModemManager, so switch those installs
    if has_older_package "plasma-settings" "21.12-2"; then
        echo "==> Reconfiguring system to use ModemManager..."
        systemctl disable --now --quiet ofono ofonoctl
        systemctl enable --now --quiet ModemManager
    fi

    # Notify the user(s) if they need to update their passwords
    local OUTDATED_USER OUTDATED_USERS
    local MESSAGE DESCRIPTION1 DESCRIPTION2
    local NOTIFY_USERID CONSOLE_ALERTED

    OUTDATED_USERS=$(grep '$1' /etc/shadow 2> /dev/null | cut -d ':' -f 1)
    if [[ ! -z ${OUTDATED_USERS} ]]; then
        MESSAGE='Your password needs to be updated.'
        DESCRIPTION1='Because of a system library update, please run "passwd" utility'
        DESCRIPTION2='to update your password before rebooting.'
        CONSOLE_ALERTED=false

        for OUTDATED_USER in ${OUTDATED_USERS}; do
            if users | grep -q -x "${OUTDATED_USER}"; then
                if [[ "${CONSOLE_ALERTED}" = false ]]; then
                    echo "==> ${MESSAGE}"
                    echo "    ${DESCRIPTION1}"
                    echo "    ${DESCRIPTION2}"
                    CONSOLE_ALERTED=true
                fi

                NOTIFY_USERID=$(id -u ${OUTDATED_USER})
                if [[ -e "/run/user/${NOTIFY_USERID}/bus" ]]; then
                    sudo -u ${OUTDATED_USER} \
                        sh -c "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${NOTIFY_USERID}/bus \
                               notify-send -u critical '${MESSAGE}' '${DESCRIPTION1} ${DESCRIPTION2}'"
                fi
            fi
        done
    fi

    # Fix nss 3.51.1-1 upgrade
    if has_older_package "nss" "3.51.1-1"; then
        echo "==> Fixing file conflicts for 'nss' update..."
        db_unlock
        pacman -S nss --noconfirm --overwrite /usr/lib\*/p11-kit-trust.so
    fi

    # Fix zn_poly 0.9.2-2 upgrade
    if has_older_package "zn_poly" "0.9.2-2"; then
        echo "==> Fixing file conflicts for 'zn_poly' update..."
        db_unlock
        pacman -S zn_poly --noconfirm --overwrite usr/lib/libzn_poly-0.9.so
    fi

    # Fix hplip 3.20.3-2 upgrade
    if has_older_package "hplip" "1:3.20.3-2"; then
        echo "==> Fixing file conflicts for 'hplip' update..."
        db_unlock
        pacman -S hplip --noconfirm --overwrite /usr/share/hplip/\*
    fi

    # Fix firewalld 0.8.1-2 upgrade
    if has_older_package "firewalld" "0.8.1-2"; then
        echo "==> Fixing file conflicts for 'firewalld' update..."
        db_unlock
        pacman -S firewalld --noconfirm --overwrite /usr/lib/python3.8/site-packages/firewall/\*
    fi

    # Replace gtk3-classic with regular upstream gtk3 unless reinstalled since m-s 20191208-1
    if [[ "$(vercmp $2 20191208)" -lt 0 ]] && \
       has_package "gtk3-classic"; then
        echo "==> Replacing 'gkt3-classic' with regular 'gtk3' package..."
        echo "    If you want to continue using the 'gtk3-classic' or 'gth3-mushroom'"
        echo "    version, please install it manually from AUR."
        db_unlock
        pacman --noconfirm -Syy
        pacman -Rdd --noconfirm gtk3-classic
        pacman -S --noconfirm gtk3
    fi

    # Adjust file permissions for accountsservice >= 0.6.55
    if has_older_package "accountsservice" "0.6.55-1"; then
        echo "==> Adjusting file permissions for 'accountsservice' 0.6.55..."
        chmod 0700 /var/lib/AccountsService/users
        chmod 0755 /var/lib/AccountsService/icons
    fi
}
