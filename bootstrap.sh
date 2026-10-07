#!/usr/bin/env bash
set -euo pipefail

# Bootstrap script for x-dockhand-agent.
# Idempotent: safe to run multiple times on the same host.
#
# What it does, in order:
#   1. Ensures .env exists (copies from env.example if missing)
#   2. Suggests the system hostname for LOCAL_HOSTNAME
#   3. Ensures every required variable in .env has a real value
#      (prompts interactively for anything missing/placeholder)
#   4. Installs compose.yaml and .env in /srv/stacks/x-dockhand-agent
#   5. Ensures the external Docker volume exists
#   6. Starts the deployed stack with Docker Compose

# Resolve paths from the script location, even when invoked elsewhere.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$SCRIPT_DIR"
umask 077
DEPLOY_DIR="/srv/stacks/x-dockhand-agent"
ENV_FILE=".env"
ENV_EXAMPLE="env.example"

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required to check Dockhand Main." >&2
  exit 1
fi

# List every variable the compose file actually needs.
REQUIRED_VARS=(
  DH_MAIN_HOSTNAME
  DH_TOKEN
)

# Variables that should be read silently (not echoed to the terminal).
SECRET_VARS=(
  DH_TOKEN
)

# --- Step 1: ensure .env exists ---------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ENV_EXAMPLE" ]]; then
    echo "No .env found - creating one from $ENV_EXAMPLE"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  else
    echo "No .env or $ENV_EXAMPLE found - creating an empty .env"
    touch "$ENV_FILE"
  fi
fi

# Protect existing local configuration as well as newly created files.
chmod 600 "$ENV_FILE"

# --- Helpers ----------------------------------------------------------------

# Get the current value of a key from .env (empty string if not set).
get_env_value() {
  local key="$1"

  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null \
    | tail -n1 \
    | cut -d '=' -f2- \
    || true
}

# Set (or update) a key in .env.
# Values are passed to awk through the environment, so characters such as
# | & \ / in tokens are written literally.
set_env_value() {
  local key="$1"
  local value="$2"
  local tmp_file

  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    tmp_file="$(mktemp "${ENV_FILE}.XXXXXX")"
    KEY="$key" VALUE="$value" awk '
      index($0, ENVIRON["KEY"] "=") == 1 { print ENVIRON["KEY"] "=" ENVIRON["VALUE"]; next }
      { print }
    ' "$ENV_FILE" > "$tmp_file"
    # Rewrite in place so .env keeps its owner and 600 permissions.
    cat "$tmp_file" > "$ENV_FILE"
    rm -f "$tmp_file"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# A value counts as "not really set" if it's empty or still looks like a
# placeholder, e.g. changeme, your_token_here, todo, xxx or <something>.
is_placeholder() {
  local value="$1"

  if [[ -z "$value" ]]; then
    return 0
  fi

  if [[ "$value" =~ ^\<.*\>$ ]] \
    || [[ "$value" =~ ^(changeme|your_.*_here|todo|xxx)$ ]]; then
    return 0
  fi

  return 1
}

is_secret_var() {
  local key="$1"

  for s in "${SECRET_VARS[@]}"; do
    [[ "$s" == "$key" ]] && return 0
  done

  return 1
}

# --- Step 2: configure LOCAL_HOSTNAME ---------------------------------------

SYSTEM_HOSTNAME="$(hostname)"
CURRENT_LOCAL_HOSTNAME="$(get_env_value "LOCAL_HOSTNAME")"

# If LOCAL_HOSTNAME already has a real value, use it as the suggested value.
# Otherwise suggest the system hostname.
if is_placeholder "$CURRENT_LOCAL_HOSTNAME"; then
  SUGGESTED_HOSTNAME="$SYSTEM_HOSTNAME"
else
  SUGGESTED_HOSTNAME="$CURRENT_LOCAL_HOSTNAME"
fi

read -r -p "LOCAL_HOSTNAME [$SUGGESTED_HOSTNAME]: " LOCAL_HOSTNAME_INPUT

LOCAL_HOSTNAME="${LOCAL_HOSTNAME_INPUT:-$SUGGESTED_HOSTNAME}"

if [[ -z "$LOCAL_HOSTNAME" ]]; then
  echo "Error: LOCAL_HOSTNAME cannot be empty. Aborting." >&2
  exit 1
fi

set_env_value "LOCAL_HOSTNAME" "$LOCAL_HOSTNAME"

# Export it as well, so docker compose can use it immediately even if needed
# for variable interpolation outside env_file handling.
export LOCAL_HOSTNAME

echo "LOCAL_HOSTNAME=$LOCAL_HOSTNAME"

# --- Step 3: fill in missing/placeholder variables --------------------------

missing_any=false

for var in "${REQUIRED_VARS[@]}"; do
  current_value="$(get_env_value "$var")"

  if is_placeholder "$current_value"; then
    missing_any=true

    if is_secret_var "$var"; then
      read -r -s -p "Enter value for $var (input hidden): " new_value
      echo
    else
      read -r -p "Enter value for $var: " new_value
    fi

    if [[ -z "$new_value" ]]; then
      echo "Error: $var cannot be empty. Aborting." >&2
      exit 1
    fi

    set_env_value "$var" "$new_value"
  fi
done

if [[ "$missing_any" == true ]]; then
  echo ".env is now complete."
else
  echo ".env already has all required variables set."
fi

# Check WSS transport only; agent authentication is checked in container logs.
# curl can time out after a successful upgrade because the socket stays open.
check_main_wss() {
  local main_hostname="$1"
  local http_code curl_status=0

  echo "Checking wss://${main_hostname}/api/hawser/connect ..."
  http_code="$(curl --http1.1 --connect-timeout 5 --max-time 5 \
    -sS -o /dev/null -w '%{http_code}' \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://${main_hostname}/api/hawser/connect")" || curl_status=$?

  if [[ "$http_code" == "101" ]] \
    && [[ "$curl_status" == "0" || "$curl_status" == "28" ]]; then
    echo "WSS upgrade accepted (HTTP 101)."
    return 0
  fi

  echo "WSS check failed: HTTP ${http_code:-000}, curl exit code $curl_status." >&2
  return 1
}

while true; do
  main_hostname="$(get_env_value "DH_MAIN_HOSTNAME")"
  # A hostname or hostname:port is expected, without scheme or path.
  if [[ "$main_hostname" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
    if check_main_wss "$main_hostname"; then
      break
    fi
  else
    echo "Invalid DH_MAIN_HOSTNAME. Use a hostname, optionally with :port; no scheme or path." >&2
  fi

  read -r -p "[r] Retry, [e] Edit hostname, [q] Quit: " check_action
  case "$check_action" in
    r|R) ;;
    e|E)
      read -r -p "DH_MAIN_HOSTNAME [$main_hostname]: " new_hostname
      if [[ -n "$new_hostname" ]]; then
        if [[ "$new_hostname" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
          set_env_value "DH_MAIN_HOSTNAME" "$new_hostname"
        else
          echo "Invalid hostname. Value was not saved." >&2
        fi
      fi
      ;;
    q|Q) echo "Aborted. Stack was not started."; exit 1 ;;
    *) echo "Choose r, e or q." ;;
  esac
done

# Ensure Compose uses the hostname that passed the check, even if the shell
# already has a different exported DH_MAIN_HOSTNAME.
export DH_MAIN_HOSTNAME="$main_hostname"

# --- Step 4: prepare privileged deployment ---------------------------------

if [[ ! -f compose.yaml ]]; then
  echo "Error: compose.yaml is missing from $SCRIPT_DIR." >&2
  exit 1
fi

# Membership in the root group does not grant sudo privileges.
# Use sudo for deployment, or run directly when already root.
PRIVILEGED=()
if [[ "$EUID" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo is required for deployment to $DEPLOY_DIR." >&2
    exit 1
  fi
  sudo -v
  PRIVILEGED=(sudo)
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker is not installed or not available in PATH." >&2
  exit 1
fi
if ! "${PRIVILEGED[@]}" docker info >/dev/null 2>&1; then
  echo "Error: Docker daemon is not running or is not accessible." >&2
  exit 1
fi
if ! "${PRIVILEGED[@]}" docker compose version >/dev/null 2>&1; then
  echo "Error: Docker Compose plugin is not available." >&2
  exit 1
fi

# These files form the deployment configuration. Keep .env private in both
# locations. install sets ownership and permissions explicitly.
echo "Installing deployment files in $DEPLOY_DIR ..."
"${PRIVILEGED[@]}" install -d -o root -g root -m 755 "$DEPLOY_DIR"
"${PRIVILEGED[@]}" install -o root -g root -m 644 \
  "$SCRIPT_DIR/compose.yaml" "$DEPLOY_DIR/compose.yaml"
"${PRIVILEGED[@]}" install -o root -g root -m 600 \
  "$SCRIPT_DIR/$ENV_FILE" "$DEPLOY_DIR/.env"

# Validate the copied configuration without printing resolved secrets.
# Clear inherited interpolation variables so deployment uses its own .env.
"${PRIVILEGED[@]}" env -u LOCAL_HOSTNAME -u DH_MAIN_HOSTNAME -u DH_TOKEN \
  docker compose --project-directory "$DEPLOY_DIR" \
  --env-file "$DEPLOY_DIR/.env" -f "$DEPLOY_DIR/compose.yaml" config --quiet

# --- Step 5: ensure external Docker volume exists ---------------------------

VOLUME_NAME="x-dockhand-stacks_${LOCAL_HOSTNAME}"

if "${PRIVILEGED[@]}" docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  echo "Volume '$VOLUME_NAME' already exists."
else
  echo "Volume '$VOLUME_NAME' not found - creating it."
  "${PRIVILEGED[@]}" docker volume create "$VOLUME_NAME" >/dev/null
fi

# --- Step 6: start the deployed stack ---------------------------------------

echo "Starting the stack from $DEPLOY_DIR ..."
"${PRIVILEGED[@]}" env -u LOCAL_HOSTNAME -u DH_MAIN_HOSTNAME -u DH_TOKEN \
  docker compose --project-directory "$DEPLOY_DIR" \
  --env-file "$DEPLOY_DIR/.env" -f "$DEPLOY_DIR/compose.yaml" up -d

echo
echo "Done."
echo "LOCAL_HOSTNAME : $LOCAL_HOSTNAME"
echo "Docker volume  : $VOLUME_NAME"
echo "Deployment    : $DEPLOY_DIR"
echo "Check agent connection and authentication with:"
echo "  sudo docker logs --tail 50 -f x-dockhand-agent"
