#!/usr/bin/env bash
# Install or uninstall the macOS LoginWindow LaunchAgent (com.remoter.agent.loginwindow)
# so RemoterAgent stays reachable and unlockable even at the macOS LoginWindow / Lock Screen.
#
# Usage:
#   sudo bash scripts/install-loginwindow-agent.sh
#   sudo bash scripts/install-loginwindow-agent.sh --uninstall
set -euo pipefail

LABEL="com.remoter.agent.loginwindow"
PLIST_PATH="/Library/LaunchAgents/${LABEL}.plist"
SYSTEM_CONFIG_DIR="/Library/Application Support/Remoter"
APP_PATH="/Applications/RemoterAgent.app"
BIN_PATH="${APP_PATH}/Contents/MacOS/RemoterAgent"
LOG_PATH="/var/log/remoter-loginwindow.log"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: This script requires root privileges. Please run with sudo:" >&2
    echo "  sudo bash \"$0\" $*" >&2
    exit 1
fi

ACTION="install"
for arg in "$@"; do
    case "$arg" in
        --uninstall)
            ACTION="uninstall"
            ;;
        -h|--help)
            echo "Usage: sudo bash $0 [--uninstall]"
            echo "  (default)    Sync Remoter config and install LoginWindow LaunchAgent"
            echo "  --uninstall  Remove LoginWindow LaunchAgent and /Library/Application Support/Remoter"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ "${ACTION}" == "uninstall" ]]; then
    echo "==> Uninstalling ${LABEL}..."
    if [[ -f "${PLIST_PATH}" ]]; then
        launchctl bootout "system/${LABEL}" 2>/dev/null || true
        launchctl unload -w "${PLIST_PATH}" 2>/dev/null || true
        rm -f "${PLIST_PATH}"
        echo "    Removed ${PLIST_PATH}"
    else
        echo "    ${PLIST_PATH} not present (already removed)"
    fi

    if [[ -d "${SYSTEM_CONFIG_DIR}" ]]; then
        rm -rf "${SYSTEM_CONFIG_DIR}"
        echo "    Removed ${SYSTEM_CONFIG_DIR}"
    fi

    echo "==> Uninstall complete."
    exit 0
fi

# Verify /Applications/RemoterAgent.app is installed
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Warning: ${BIN_PATH} not found or not executable." >&2
    echo "         Build & install it first with: bash scripts/build-app.sh --install" >&2
fi

# Resolve invoking user's home directory
INVOKING_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || echo "")}"
USER_HOME=""
if [[ -n "${INVOKING_USER}" && "${INVOKING_USER}" != "root" ]]; then
    USER_HOME="$(dscl . -read "/Users/${INVOKING_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
fi
if [[ -z "${USER_HOME}" ]]; then
    USER_HOME="${HOME}"
fi

USER_CONFIG_DIR="${USER_HOME}/Library/Application Support/Remoter"

echo "==> Syncing Remoter config to ${SYSTEM_CONFIG_DIR}..."
mkdir -p "${SYSTEM_CONFIG_DIR}"
chown root:wheel "${SYSTEM_CONFIG_DIR}"
chmod 700 "${SYSTEM_CONFIG_DIR}"

if [[ -f "${USER_CONFIG_DIR}/config.json" ]]; then
    cp "${USER_CONFIG_DIR}/config.json" "${SYSTEM_CONFIG_DIR}/config.json"
    chown root:wheel "${SYSTEM_CONFIG_DIR}/config.json"
    chmod 600 "${SYSTEM_CONFIG_DIR}/config.json"
    echo "    Synced config.json from ${USER_CONFIG_DIR}"
else
    echo "Warning: ${USER_CONFIG_DIR}/config.json not found; LoginWindow agent will generate a PIN on first run." >&2
fi

# Sync optional tokens/certs if present in user's Remoter support dir
for extra in tokens.json server.crt server.key; do
    if [[ -f "${USER_CONFIG_DIR}/${extra}" ]]; then
        cp "${USER_CONFIG_DIR}/${extra}" "${SYSTEM_CONFIG_DIR}/${extra}"
        chown root:wheel "${SYSTEM_CONFIG_DIR}/${extra}"
        chmod 600 "${SYSTEM_CONFIG_DIR}/${extra}"
        echo "    Synced ${extra}"
    fi
done

echo "==> Installing ${PLIST_PATH}..."
cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_PATH}</string>
        <string>--loginwindow</string>
    </array>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>LoginWindow</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>2</integer>
    <key>StandardOutPath</key>
    <string>${LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_PATH}</string>
</dict>
</plist>
EOF

chown root:wheel "${PLIST_PATH}"
chmod 644 "${PLIST_PATH}"

echo "==> LoginWindow LaunchAgent installed: ${PLIST_PATH}"
echo "    Logs: ${LOG_PATH}"
echo "    Note: LoginWindow agents are automatically loaded by launchd at the macOS LoginWindow"
echo "          (after reboot or logout). Ensure ${APP_PATH} has Screen Recording & Accessibility"
echo "          permissions in System Settings -> Privacy & Security."
