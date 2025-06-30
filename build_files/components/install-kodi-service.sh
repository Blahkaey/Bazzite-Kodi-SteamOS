#!/bin/bash
set -euo pipefail

source "/ctx/utility.sh"

setup_kodi_system_files() {
    log_subsection "Setting up Kodi system configuration"

    cp /ctx/components/system-scripts/update-kodilauncher /usr/bin/
    chmod +x /usr/bin/update-kodilauncher

    # Install udev rules
    cp /ctx/config/udev/99-kodi.rules /usr/lib/udev/rules.d/

    # Install tmpfiles configuration
    cp /ctx/config/tmpfiles/kodi-standalone.conf /usr/lib/tmpfiles.d/

    # Install sysusers configuration
    cp /ctx/config/sysusers/kodi-standalone.conf /usr/lib/sysusers.d/

    # Create kodi user and groups
    systemd-sysusers
    
    # Disable password expiry for kodi user
    chage -E -1 kodi
    chage -M -1 kodi

    log_success "Kodi system configuration completed"
}

install_kodi_gbm_service() {
    log_subsection "Installing kodi-gbm systemd service"

    # Install systemd service
    cp /ctx/config/systemd/kodi-gbm.service /usr/lib/systemd/system/

    # Don't enable by default
    systemctl disable kodi-gbm.service 2>/dev/null || true

    log_success "kodi-gbm service installed"
}

setup_kodi_default_files() {
    log_subsection "Installing default Kodi user files"

    # Create directory for default Kodi files
    local defaults_dir="/usr/share/kodi-defaults"
    mkdir -p "$defaults_dir/userdata/scripts"

    # Create favourites.xml
    cat > "$defaults_dir/userdata/favourites.xml" << 'EOF'
<favourites>
    <favourite name="Switch To GameMode">RunScript(special://masterprofile/scripts/exit_to_gamemode.py)</favourite>
</favourites>
EOF

    # Create exit_to_gamemode.py script
    cat > "$defaults_dir/userdata/scripts/exit_to_gamemode.py" << 'EOF'
#!/usr/bin/env python3
import xbmc
import subprocess
from datetime import datetime

def log(msg, level=xbmc.LOGINFO):
    xbmc.log(f"[KODI-EXIT] {msg}", level)

def main():
    log("=== Kodi exit script started ===")
    log(f"Script called at: {datetime.now()}")

    try:
        user_result = subprocess.run(['whoami'], capture_output=True, text=True)
        log(f"Running as user: {user_result.stdout.strip()}")

        log("Executing: /usr/bin/kodi-request-gamemode")
        result = subprocess.run(
            ['/usr/bin/kodi-request-gamemode'],
            capture_output=True,
            text=True,
            timeout=30  # 30 second timeout
        )

        log(f"Return code: {result.returncode}")
        if result.stdout:
            log(f"STDOUT: {result.stdout}")
        if result.stderr:
            log(f"STDERR: {result.stderr}", xbmc.LOGERROR)

        if result.returncode == 0:
            msg = 'Succeeded'
            log("Switch to gamemode succeeded")
        else:
            msg = f'Failed (code: {result.returncode})'
            log(f"Switch to gamemode failed with code: {result.returncode}", xbmc.LOGERROR)

        xbmc.executebuiltin('Notification("Switch to GameMode", "%s")' % msg)

    except subprocess.TimeoutExpired:
        log("Command timed out after 30 seconds", xbmc.LOGERROR)
        xbmc.executebuiltin('Notification("Switch to GameMode", "Timeout")')
    except Exception as e:
        log(f"Unexpected error: {str(e)}", xbmc.LOGFATAL)
        xbmc.executebuiltin('Notification("Switch to GameMode", "Error: %s")' % str(e))
    finally:
        log("=== Kodi exit script finished ===")

if __name__ == "__main__":
    main()
EOF

    chmod +x "$defaults_dir/userdata/scripts/exit_to_gamemode.py"

    log_success "Default Kodi files installed"
}

setup_kodi_system_files
install_kodi_gbm_service
setup_kodi_default_files

log_success "Kodi service setup completed"
