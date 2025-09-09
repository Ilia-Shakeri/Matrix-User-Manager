#!/usr/bin/env bash
# matrix_user_manager.sh
# Interactive Matrix (Synapse) user management tool
# - autodetects synapse & postgres containers
# - detects sqlite vs postgres from homeserver.yaml
# - can list users, show user info, create user, reset password, lock/unlock, deactivate, backup DB, run custom queries
# - UI: whiptail with auto-install (fallback to simple text prompts)
# Author: Ilia-Shakeri
# Usage: sudo chmod +x matrix_user_manager.sh
#        sudo ./matrix_user_manager.sh

set -euo pipefail
IFS=$'\n\t'

### ---------- CONFIG ----------
SCRIPT_NAME="matrix_user_manager.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="${SCRIPT_DIR}/${SCRIPT_NAME%.*}.log"
TMPDIR="/tmp/matrix_user_manager.$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

# Colors (for fallback text UI)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Minimum required host tools
REQUIRED_CMDS=(docker awk sed grep cat date)

# ---------- UTIL ----------
log() {
  local msg="[$(date '+%F %T')] $*"
  echo "$msg" >> "$LOGFILE"
  if $USE_WHIPTAIL; then
    echo "$msg"
  fi
}

silent_log() {
  echo "[$(date '+%F %T')] $*" >> "$LOGFILE"
}

check_requirements() {
  local miss=0
  for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd"
      miss=1
    fi
  done
  if [[ $miss -eq 1 ]]; then
    echo "Install missing utilities and re-run as root (or a user in docker group)." >&2
    exit 1
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  else
    echo "unknown"
  fi
}

install_whiptail() {
  local pkg_mgr
  pkg_mgr=$(detect_package_manager)
  
  echo -e "${CYAN}Installing whiptail...${NC}"
  case "$pkg_mgr" in
    apt)
      apt-get update && apt-get install -y whiptail
      ;;
    yum)
      yum install -y newt
      ;;
    dnf)
      dnf install -y newt
      ;;
    pacman)
      pacman -S --noconfirm libnewt
      ;;
    *)
      echo -e "${RED}Unknown package manager. Please install whiptail/newt manually.${NC}"
      return 1
      ;;
  esac
}

setup_ui() {
  USE_WHIPTAIL=false
  
  if command -v whiptail >/dev/null 2>&1; then
    USE_WHIPTAIL=true
    return
  fi
  
  echo -e "${YELLOW}Whiptail not found. This tool provides a much better experience with whiptail.${NC}"
  echo -e "${CYAN}Would you like to install whiptail for better UI? [Y/n]:${NC} "
  read -r response
  
  if [[ -z "$response" || "$response" =~ ^[Yy] ]]; then
    if [[ $EUID -ne 0 ]]; then
      echo -e "${RED}Root privileges required to install whiptail. Please run as root or install whiptail manually.${NC}"
      echo "Continuing with text-based interface..."
      return
    fi
    
    if install_whiptail; then
      echo -e "${GREEN}Whiptail installed successfully. Restarting script...${NC}"
      sleep 2
      exec "$0" "$@"
    else
      echo -e "${YELLOW}Failed to install whiptail. Continuing with text-based interface...${NC}"
    fi
  else
    echo -e "${CYAN}Continuing with text-based interface...${NC}"
  fi
}

ui_msg() {
  local title="${1:-Message}"
  local text="${2:-}"
  if $USE_WHIPTAIL; then
    whiptail --title "$title" --msgbox "$text" 15 80
  else
    # print UI to stderr so command-substitution callers don't capture it
    echo -e "${CYAN}=== $title ===${NC}" >&2
    echo -e "$text" >&2
    echo -e "${YELLOW}Press Enter to continue...${NC}" >&2
    # wait for user on stdin
    read -r
  fi
}

ui_input() {
  local title="$1"; local prompt="$2"; local default="${3:-}"
  if $USE_WHIPTAIL; then
    whiptail --title "$title" --inputbox "$prompt" 11 70 "$default" 3>&1 1>&2 2>&3
  else
    # print title to stderr (visible), but return only the user's input on stdout
    echo -e "${CYAN}$title${NC}" >&2
    if [[ -n "$default" ]]; then
      printf "%s" "$prompt [$default]: " >&2
    else
      printf "%s" "$prompt: " >&2
    fi
    # read from stdin (user types), store in val
    read -r val
    # echo only the value (or default) to stdout for capture by callers
    echo "${val:-$default}"
  fi
}

ui_password() {
  local title="$1"; local prompt="$2"
  if $USE_WHIPTAIL; then
    whiptail --title "$title" --passwordbox "$prompt" 12 70 3>&1 1>&2 2>&3
  else
    # show title/prompt to stderr; read password silently from stdin
    echo -e "${CYAN}$title${NC}" >&2
    printf "%s" "$prompt: " >&2
    # read silently
    read -rs val
    echo "" >&2
    # return password on stdout only
    echo "$val"
  fi
}

ui_menu() {
  local title="$1"; shift
  local prompt="$1"; shift

  if $USE_WHIPTAIL; then
    whiptail --title "$title" --menu "$prompt" 25 90 15 --default-item "0" "$@" 3>&1 1>&2 2>&3
  else
    local -a menu_items=("$@")

    while true; do
      # Print the menu to STDERR so it shows on terminal even when caller uses $(...)
      echo "" >&2
      echo -e "${CYAN}=== $title ===${NC}" >&2
      echo "$prompt" >&2
      echo "" >&2

      # Print menu items to STDERR
      local i=0
      while (( i < ${#menu_items[@]} )); do
        local option_key="${menu_items[$i]}"
        local option_desc="${menu_items[$((i+1))]}"
        echo "$option_key) $option_desc" >&2
        i=$((i+2))
      done
      echo "" >&2

      # Prompt (print prompt to STDERR so it's visible)
      echo -n "Choose (enter number): " >&2
      read -r choice
      choice="${choice##[ \t]*}"  # trim leading spaces
      choice="${choice%%[ \t]*}"  # trim trailing spaces

      # Empty input → ask again
      if [[ -z "$choice" ]]; then
        echo -e "${YELLOW}Please enter a number.${NC}" >&2
        continue
      fi

      # Validate choice
      i=0
      while (( i < ${#menu_items[@]} )); do
        if [[ "${menu_items[$i]}" == "$choice" ]]; then
          # return user's selection on stdout (so caller captures it)
          echo "$choice"
          return 0
        fi
        i=$((i+2))
      done

      echo -e "${RED}Invalid choice. Please try again.${NC}" >&2
    done
  fi
}


confirm() {
  local prompt="${1:-Are you sure?}"
  if $USE_WHIPTAIL; then
    if whiptail --title "Confirm" --yesno "$prompt" 8 60; then return 0; else return 1; fi
  else
    echo -e "${YELLOW}$prompt${NC}"
    read -r -p "[y/N]: " y
    [[ $y =~ ^[Yy] ]] && return 0 || return 1
  fi
}

show_results() {
  local title="$1"
  local content="$2"
  if $USE_WHIPTAIL; then
    whiptail --title "$title" --msgbox "$content" 24 120 --scrolltext
  else
    # print result to stderr (visible), then wait for Enter
    echo -e "${GREEN}=== $title ===${NC}" >&2
    echo "$content" >&2
    echo "" >&2
    echo -e "${YELLOW}Press Enter to continue...${NC}" >&2
    read -r
  fi
}

# ---------- DETECTION ----------
SYNAPSE_CONTAINER=""
POSTGRES_CONTAINER=""
HOMESERVER_YAML_PATH=""
DOMAIN=""

detect_containers() {
  silent_log "Starting container detection..."
  
  # Find probable synapse container with better patterns
  local syns
  syns=$(docker ps --format "{{.Names}} {{.Image}}" | grep -iE "synapse|matrix.*synapse|.*matrix.*" | head -n5 || true)
  
  if [[ -n "$syns" ]]; then
    if [[ $(echo "$syns" | wc -l) -eq 1 ]]; then
      SYNAPSE_CONTAINER=$(echo "$syns" | awk '{print $1}')
      silent_log "Auto-detected single synapse container: $SYNAPSE_CONTAINER"
    else
      # Multiple containers found, let user choose
      if ! $USE_WHIPTAIL; then
        echo
        echo "----------------------------------------"
        echo -e "${CYAN}Multiple Matrix/Synapse containers found:${NC}"
        
        # Display numbered list
        local i=1
        while IFS= read -r line; do
          local name=$(echo "$line" | awk '{print $1}')
          local image=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
          echo "$i) $name ($image)"
          i=$((i+1))
        done <<< "$syns"
        echo
      fi
      
      local containers=()
      while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local image=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
        containers+=("$name" "$image")
      done <<< "$syns"
      
      local choice
      local max_choice=$(echo "$syns" | wc -l)
      
      while true; do
        if $USE_WHIPTAIL; then
          choice=$(ui_menu "Select Synapse Container" "Multiple Matrix/Synapse containers found:" "${containers[@]}")
          if [[ -n "$choice" ]]; then
            break
          fi
        else
          read -r -p "Choose container (enter number 1-$max_choice or container name): " choice
          
          # If numeric choice, convert to container name
          if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local line_num=$choice
            if [[ $line_num -gt 0 && $line_num -le $max_choice ]]; then
              choice=$(echo "$syns" | sed -n "${line_num}p" | awk '{print $1}')
              break
            else
              echo -e "${RED}Invalid number. Please enter 1-$max_choice${NC}"
              continue
            fi
          else
            # Check if container name exists in list
            if echo "$syns" | grep -q "^$choice "; then
              break
            else
              echo -e "${RED}Container '$choice' not found in list. Try again.${NC}"
              continue
            fi
          fi
        fi
      done
      
      SYNAPSE_CONTAINER="$choice"
      silent_log "User selected synapse container: $SYNAPSE_CONTAINER"
    fi
  fi

  # Find Postgres container with better detection
  local pgs
  pgs=$(docker ps --format "{{.Names}} {{.Image}}" | grep -iE "postgres|postgresql" | head -n5 || true)
  
  if [[ -n "$pgs" ]]; then
    if [[ $(echo "$pgs" | wc -l) -eq 1 ]]; then
      POSTGRES_CONTAINER=$(echo "$pgs" | awk '{print $1}')
      silent_log "Auto-detected single postgres container: $POSTGRES_CONTAINER"
    else
      # Multiple postgres containers, let user choose or skip
      if ! $USE_WHIPTAIL; then
        echo
        echo "----------------------------------------"
        echo -e "${CYAN}Multiple Postgres containers found:${NC}"
        echo "0) Skip - Use SQLite instead"
        
        local i=1
        while IFS= read -r line; do
          local name=$(echo "$line" | awk '{print $1}')
          local image=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
          echo "$i) $name ($image)"
          i=$((i+1))
        done <<< "$pgs"
        echo
      fi
      
      local containers=()
      containers+=("skip" "Skip - Use SQLite instead")
      while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local image=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
        containers+=("$name" "$image")
      done <<< "$pgs"
      
      local choice
      if $USE_WHIPTAIL; then
        choice=$(ui_menu "Select Postgres Container" "Multiple Postgres containers found (or skip for SQLite):" "${containers[@]}")
      else
        local max_choice=$(echo "$pgs" | wc -l)
        read -r -p "Choose container (enter number 0-$max_choice or container name, 0 for SQLite): " choice
        # If numeric choice, convert to container name
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          local line_num=$choice
          if [[ $line_num -eq 0 ]]; then
            choice="skip"
          elif [[ $line_num -gt 0 && $line_num -le $max_choice ]]; then
            choice=$(echo "$pgs" | sed -n "${line_num}p" | awk '{print $1}')
          else
            echo -e "${RED}Invalid number. Skipping to SQLite.${NC}"
            choice="skip"
          fi
        fi
      fi
      
      if [[ "$choice" != "skip" && -n "$choice" ]]; then
        POSTGRES_CONTAINER="$choice"
        silent_log "User selected postgres container: $POSTGRES_CONTAINER"
      fi
    fi
  fi

  # If synapse container not found, prompt user with validation
  if [[ -z "$SYNAPSE_CONTAINER" ]]; then
    local all_containers
    all_containers=$(docker ps --format "{{.Names}} {{.Image}}" || true)
    if [[ -n "$all_containers" && ! $USE_WHIPTAIL ]]; then
      echo
      echo "----------------------------------------"
      echo -e "${CYAN}Available containers:${NC}"
      echo "$all_containers"
      echo
    fi
    
    while true; do
      SYNAPSE_CONTAINER=$(ui_input "Synapse Container" "Cannot auto-detect Synapse container. Enter container name:" "")
      if [[ -z "$SYNAPSE_CONTAINER" ]]; then
        echo -e "${RED}Synapse container required.${NC}" >&2
        exit 1
      fi
      
      # Verify container exists and is running
      if docker ps --format "{{.Names}}" | grep -q "^${SYNAPSE_CONTAINER}$"; then
        break
      else
        echo -e "${RED}Container '$SYNAPSE_CONTAINER' not found or not running. Try again.${NC}"
      fi
    done
    
    silent_log "User manually entered synapse container: $SYNAPSE_CONTAINER"
  fi

  silent_log "Final containers - Synapse: $SYNAPSE_CONTAINER, Postgres: ${POSTGRES_CONTAINER:-none}"
}

# Read homeserver.yaml from synapse container with better path detection
read_homeserver_yaml() {
  local possible_paths=(
    "/data/homeserver.yaml"
    "/etc/matrix-synapse/homeserver.yaml" 
    "/app/homeserver.yaml"
    "/synapse/config/homeserver.yaml"
    "/config/homeserver.yaml"
  )
  
  silent_log "Searching for homeserver.yaml in container $SYNAPSE_CONTAINER"
  HOMESERVER_YAML_PATH=""
  for path in "${possible_paths[@]}"; do
    if docker exec "$SYNAPSE_CONTAINER" test -f "$path" 2>/dev/null; then
      HOMESERVER_YAML_PATH="$path"
      break
    fi
  done
  
  if [[ -z "$HOMESERVER_YAML_PATH" ]]; then
    # Search for homeserver.yaml files
    local found_configs
    found_configs=$(docker exec "$SYNAPSE_CONTAINER" find / -name "homeserver.yaml" -type f 2>/dev/null | head -10 || true)
    
    if [[ -n "$found_configs" && ! $USE_WHIPTAIL ]]; then
      echo -e "${CYAN}Found config files in container:${NC}"
      echo "$found_configs"
      echo
    fi
    
    if [[ -n "$found_configs" ]]; then
      local default_path
      default_path=$(echo "$found_configs" | head -n1)
      HOMESERVER_YAML_PATH=$(ui_input "Homeserver Config" "Enter path to homeserver.yaml inside the container:" "$default_path")
    else
      HOMESERVER_YAML_PATH=$(ui_input "Homeserver Config" "Enter path to homeserver.yaml inside the container:" "/data/homeserver.yaml")
    fi
  fi

  HOMESERVER_CONTENT=$(docker exec "$SYNAPSE_CONTAINER" cat "$HOMESERVER_YAML_PATH" 2>/dev/null || echo "")
  if [[ -z "$HOMESERVER_CONTENT" ]]; then
    ui_msg "Error" "Unable to read homeserver.yaml from $SYNAPSE_CONTAINER:$HOMESERVER_YAML_PATH"
    exit 1
  fi
  
  # Extract domain
  DOMAIN=$(echo "$HOMESERVER_CONTENT" | grep -E "^server_name:" | head -n1 | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d '"' | tr -d "'" | tr -d ' ' || true)
  DOMAIN="${DOMAIN:-matrix.example.com}"
  
  silent_log "Found homeserver.yaml at: $HOMESERVER_YAML_PATH"
  silent_log "Domain: $DOMAIN"
}

# Detect DB type by parsing homeserver.yaml
DB_TYPE=""   # "sqlite" or "postgres"
SQLITE_PATH=""
PG_USER=""
PG_DB=""
PG_HOST=""
PG_PORT=""
PG_PASS=""

detect_database_config() {
  read_homeserver_yaml

  # Check for sqlite
  if echo "$HOMESERVER_CONTENT" | grep -q "name: sqlite3"; then
    DB_TYPE="sqlite"
    SQLITE_PATH=$(echo "$HOMESERVER_CONTENT" | awk '/database:/,/^[a-zA-Z]/ {if(/database:/) print $0}' | grep "database:" | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d '"' | tr -d "'" | head -n1 || true)
    if [[ -z "$SQLITE_PATH" ]]; then
      # Try alternative parsing
      SQLITE_PATH=$(echo "$HOMESERVER_CONTENT" | grep -A 10 "name: sqlite3" | grep "database:" | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d '"' | tr -d "'" | head -n1 || true)
    fi
    SQLITE_PATH="${SQLITE_PATH:-/data/homeserver.db}"
  fi

  # Check for psycopg2
  if echo "$HOMESERVER_CONTENT" | grep -q "name: psycopg2"; then
    DB_TYPE="postgres"
    
    # Parse postgres config
    local db_section
    db_section=$(echo "$HOMESERVER_CONTENT" | awk '/database:/,/^[a-zA-Z]/ {print}' || true)
    
    PG_USER=$(echo "$db_section" | grep "user:" | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d '"' | tr -d "'" | head -n1 || true)
    PG_PASS=$(echo "$db_section" | grep "password:" | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d '"' | tr -d "'" | head -n1 || true)
    PG_HOST=$(echo "$db_section" | grep "host:" | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d '"' | tr -d "'" | head -n1 || true)
    PG_PORT=$(echo "$db_section" | grep "port:" | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d '"' | tr -d "'" | head -n1 || true)
    PG_DB=$(echo "$db_section" | grep -E "(dbname|database):" | tail -n1 | awk -F: '{gsub(/^[ \t]+/,"",$2); print $2}' | tr -d '"' | tr -d "'" || true)
    
    # Fallback defaults
    PG_USER="${PG_USER:-synapse}"
    PG_DB="${PG_DB:-synapse}"
    PG_HOST="${PG_HOST:-localhost}"
    PG_PORT="${PG_PORT:-5432}"
  fi

  # If DB_TYPE still empty, ask user
  if [[ -z "$DB_TYPE" ]]; then
    local choice
    choice=$(ui_menu "Database Type" "Could not automatically determine database type. Choose:" \
      "sqlite" "SQLite (homeserver.db file)" \
      "postgres" "PostgreSQL database")
    
    if [[ "$choice" == "sqlite" ]]; then
      DB_TYPE="sqlite"
      SQLITE_PATH="/data/homeserver.db"
    else
      DB_TYPE="postgres"
      PG_USER="synapse"
      PG_DB="synapse"
      PG_HOST="localhost"
      PG_PORT="5432"
    fi
  fi

  # Handle postgres-specific setup
  if [[ "$DB_TYPE" == "postgres" ]]; then
    if [[ -z "$PG_PASS" ]]; then
      PG_PASS=$(ui_password "Postgres Password" "Enter Postgres password for user '$PG_USER' on database '$PG_DB'")
    fi
    
    # Verify postgres container
    if [[ -z "$POSTGRES_CONTAINER" ]]; then
      ui_msg "Error" "No Postgres container detected. Please ensure PostgreSQL is running in Docker."
      exit 1
    fi
    
    # Test connection
    if ! docker exec "$POSTGRES_CONTAINER" env PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1;" >/dev/null 2>&1; then
      ui_msg "Error" "Cannot connect to PostgreSQL database. Please check credentials."
      exit 1
    fi
  fi

  # Handle sqlite-specific setup
  if [[ "$DB_TYPE" == "sqlite" ]]; then
    local possible_paths=(
      "$SQLITE_PATH"
      "/data/homeserver.db"
      "/app/homeserver.db"
      "/synapse/data/homeserver.db"
    )
    
    local found_path=""
    for path in "${possible_paths[@]}"; do
      if docker exec "$SYNAPSE_CONTAINER" test -f "$path" 2>/dev/null; then
        found_path="$path"
        break
      fi
    done
    
    if [[ -z "$found_path" ]]; then
      # Search for .db files
      local found_dbs
      found_dbs=$(docker exec "$SYNAPSE_CONTAINER" find / -name "*.db" -type f 2>/dev/null | grep -v "/proc/" | head -10 || true)
      
      if [[ -n "$found_dbs" && ! $USE_WHIPTAIL ]]; then
        echo -e "${CYAN}Found database files in container:${NC}"
        echo "$found_dbs"
        echo
      fi
      
      if [[ -n "$found_dbs" ]]; then
        local default_db
        default_db=$(echo "$found_dbs" | head -n1)
        SQLITE_PATH=$(ui_input "SQLite Database" "Enter SQLite database path" "$default_db")
      else
        SQLITE_PATH=$(ui_input "SQLite Database" "Enter SQLite database path" "/data/homeserver.db")
      fi
    else
      SQLITE_PATH="$found_path"
    fi
  fi

  silent_log "Database config - Type: $DB_TYPE"
  if [[ "$DB_TYPE" == "sqlite" ]]; then 
    silent_log "SQLite path: $SQLITE_PATH"
  else 
    silent_log "Postgres: $PG_USER@$PG_HOST:$PG_PORT/$PG_DB"
  fi
}

# ---------- DB EXECUTION HELPERS ----------
exec_psql() {
  local sql="$1"
  docker exec "$POSTGRES_CONTAINER" env PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -d "$PG_DB" -c "$sql"
}

exec_sqlite() {
  local sql="$1"
  docker exec "$SYNAPSE_CONTAINER" sqlite3 -column -header "$SQLITE_PATH" "$sql"
}

execute_query() {
  local sql="$1"
  if [[ "$DB_TYPE" == "postgres" ]]; then
    exec_psql "$sql"
  else
    exec_sqlite "$sql"
  fi
}

# ---------- UTILITY FUNCTIONS ----------
normalize_username() {
  local input="$1"
  local username
  
  # If already full format (@user:domain), return as is
  if [[ "$input" =~ ^@.*:.* ]]; then
    username="$input"
  # If starts with @, add domain
  elif [[ "$input" =~ ^@ ]]; then
    username="${input}:${DOMAIN}"
  # If no @, add both @ and domain
  else
    username="@${input}:${DOMAIN}"
  fi
  
  echo "$username"
}

# ---------- ACTIONS ----------
list_users() {
  silent_log "Listing users..."
  local result
  local query
  
  # Use proper timestamp conversion for both databases
  if [[ "$DB_TYPE" == "postgres" ]]; then
    query="SELECT name AS username, CASE WHEN admin = 1 THEN 'YES' ELSE 'NO' END AS admin, CASE WHEN deactivated = 1 THEN 'YES' ELSE 'NO' END AS deactivated, to_timestamp(creation_ts) AS created FROM users ORDER BY creation_ts DESC LIMIT 100;"
  else
    query="SELECT name AS username, CASE WHEN admin = 1 THEN 'YES' ELSE 'NO' END AS admin, CASE WHEN deactivated = 1 THEN 'YES' ELSE 'NO' END AS deactivated, datetime(creation_ts, 'unixepoch') AS created FROM users ORDER BY creation_ts DESC LIMIT 100;"
  fi
  
  result=$(execute_query "$query" 2>&1 || echo "Error: Could not retrieve users")
  show_results "Users List" "$result"
  silent_log "Listed users successfully"
}

show_user_info() {
  local input username user_query device_query room_query
  local user_info devices rooms display

  input=$(ui_input "User Info" "Enter username (we'll add @ and domain if needed):" "")
  if [[ -z "$input" ]]; then
    ui_msg "Cancelled" "No username provided"
    return
  fi

  username=$(normalize_username "$input")

  if [[ "$DB_TYPE" == "postgres" ]]; then
    user_query="SELECT name, CASE WHEN admin = 1 THEN 'YES' ELSE 'NO' END AS admin, CASE WHEN deactivated = 1 THEN 'YES' ELSE 'NO' END AS deactivated, to_timestamp(creation_ts) AS created, user_type FROM users WHERE name='${username}';"
    device_query="SELECT device_id, display_name, to_timestamp(last_seen/1000) AS last_seen FROM devices WHERE user_id='${username}' ORDER BY last_seen DESC LIMIT 10;"
    room_query="SELECT room_id, membership FROM room_memberships WHERE user_id='${username}' AND membership IN ('join', 'invite') LIMIT 20;"
  else
    user_query="SELECT name, CASE WHEN admin = 1 THEN 'YES' ELSE 'NO' END AS admin, CASE WHEN deactivated = 1 THEN 'YES' ELSE 'NO' END AS deactivated, datetime(creation_ts, 'unixepoch') AS created, user_type FROM users WHERE name='${username}';"
    device_query="SELECT device_id, display_name, datetime(last_seen/1000, 'unixepoch') AS last_seen FROM devices WHERE user_id='${username}' ORDER BY last_seen DESC LIMIT 10;"
    room_query="SELECT room_id, membership FROM room_memberships WHERE user_id='${username}' AND membership IN ('join', 'invite') LIMIT 20;"
  fi

  user_info=$(execute_query "$user_query" 2>&1 || echo "Error getting user info")
  devices=$(execute_query "$device_query" 2>&1 || echo "No devices found")
  rooms=$(execute_query "$room_query" 2>&1 || echo "No room memberships found")

  display=$(printf "=== USER INFORMATION ===\n%s\n\n=== USER DEVICES ===\n%s\n\n=== ROOM MEMBERSHIPS ===\n%s\n" \
    "$user_info" "$devices" "$rooms")

  show_results "User Info: $username" "$display"
  silent_log "Showed info for user: $username"
}


create_user_interactive() {
  local username pass admin_flag localpart result display
  local register_cmds

  localpart=$(ui_input "Create User" "Enter username (without @ and domain):" "")
  if [[ -z "$localpart" ]]; then
    ui_msg "Cancelled" "No username provided"
    return
  fi

  pass=$(ui_password "Password" "Enter password for user '$localpart':")
  if [[ -z "$pass" ]]; then
    ui_msg "Cancelled" "No password provided"
    return
  fi

  if confirm "Make this user an admin?"; then
    admin_flag="--admin"
  else
    admin_flag=""
  fi

  if ! confirm "Create user '$localpart' with admin=${admin_flag:-no}?"; then
    ui_msg "Cancelled" "User creation cancelled"
    return
  fi

  silent_log "Creating user ${localpart} (admin=${admin_flag})"

  register_cmds=(
    "register_new_matrix_user -u '${localpart}' -p '${pass}' ${admin_flag} -c '${HOMESERVER_YAML_PATH}' http://localhost:8008"
    "python3 -m synapse.app.register_new_matrix_user -u '${localpart}' -p '${pass}' ${admin_flag} -c '${HOMESERVER_YAML_PATH}' http://localhost:8008"
    "/usr/local/bin/register_new_matrix_user -u '${localpart}' -p '${pass}' ${admin_flag} -c '${HOMESERVER_YAML_PATH}' http://localhost:8008"
  )

  local success=false
  result=""

  for cmd in "${register_cmds[@]}"; do
    result=$(docker exec "$SYNAPSE_CONTAINER" sh -c "$cmd" 2>&1 || true)
    if [[ $? -eq 0 ]] && [[ ! "$result" =~ [Ee]rror ]] && [[ ! "$result" =~ "No module named" ]]; then
      success=true
      break
    fi
  done

  if ! $success; then
    local full_username="@${localpart}:${DOMAIN}"
    local admin_val=0
    if [[ -n "$admin_flag" ]]; then admin_val=1; fi
    local creation_ts=$(date +%s)

    local hash_cmd="python3 -c 'import bcrypt; print(bcrypt.hashpw(\"${pass}\".encode(\"utf-8\"), bcrypt.gensalt()).decode(\"utf-8\"))'"
    local hashed_pass
    hashed_pass=$(docker exec "$SYNAPSE_CONTAINER" sh -c "$hash_cmd" 2>/dev/null || echo "")

    if [[ -n "$hashed_pass" ]] && [[ ! "$hashed_pass" =~ [Ee]rror ]] && [[ ! "$hashed_pass" =~ "No module named" ]]; then
      local insert_query="INSERT INTO users (name, password_hash, creation_ts, admin, deactivated, is_guest, user_type, approved) VALUES ('${full_username}', '${hashed_pass}', ${creation_ts}, ${admin_val}, 0, 0, NULL, TRUE) ON CONFLICT (name) DO NOTHING;"
      if [[ "$DB_TYPE" == "sqlite" ]]; then
        insert_query="INSERT OR IGNORE INTO users (name, password_hash, creation_ts, admin, deactivated, is_guest, user_type, approved) VALUES ('${full_username}', '${hashed_pass}', ${creation_ts}, ${admin_val}, 0, 0, NULL, 1);"
      fi
      result=$(execute_query "$insert_query" 2>&1 || echo "Error inserting user")
      if [[ ! "$result" =~ [Ee]rror ]]; then
        success=true
        result="User created directly in database: ${full_username}"
      fi
    fi
  fi

  if $success; then
    display=$(printf "Successfully created user: @%s\n\nOutput:\n%s\n" "$localpart" "$result")
    show_results "User Created" "$display"
    silent_log "User created successfully: @${localpart}:${DOMAIN}"
  else
    display=$(printf "Failed to create user: @%s\n\nError:\n%s\n\nTip: You may need to install python3-bcrypt in the Synapse container or use the Synapse admin API.\n" \
      "$localpart" "$result")
    show_results "Creation Failed" "$display"
    silent_log "Failed to create user: $result"
  fi
}

reset_password_interactive() {
  local input username pass result display
  input=$(ui_input "Reset Password" "Enter username:" "")
  if [[ -z "$input" ]]; then
    ui_msg "Cancelled" "No username provided"
    return
  fi

  username=$(normalize_username "$input")
  pass=$(ui_password "New Password" "Enter new password for '$username':")
  if [[ -z "$pass" ]]; then
    ui_msg "Cancelled" "No password provided"
    return
  fi

  if ! confirm "Reset password for user '$username'?"; then
    ui_msg "Cancelled" "Password reset cancelled"
    return
  fi

  local hash_cmd="python3 -c 'import bcrypt; print(bcrypt.hashpw(\"${pass}\".encode(\"utf-8\"), bcrypt.gensalt()).decode(\"utf-8\"))'"
  local hashed_pass
  hashed_pass=$(docker exec "$SYNAPSE_CONTAINER" sh -c "$hash_cmd" 2>/dev/null || echo "")

  if [[ -n "$hashed_pass" ]] && [[ ! "$hashed_pass" =~ [Ee]rror ]] && [[ ! "$hashed_pass" =~ "No module named" ]]; then
    local update_query="UPDATE users SET password_hash='$hashed_pass' WHERE name='$username';"
    result=$(execute_query "$update_query" 2>&1 || echo "Error updating password")
    display=$(printf "Password reset for: %s\n\nResult:\n%s\n" "$username" "$result")
    show_results "Password Reset" "$display"
    silent_log "Password reset for: $username"
  else
    display=$(printf "Could not generate password hash for: %s\n\nError: %s\n\nTip: Install python3-bcrypt in the Synapse container:\n\tdocker exec %s apt-get update && apt-get install -y python3-bcrypt\n" \
      "$username" "$hashed_pass" "$SYNAPSE_CONTAINER")
    show_results "Password Reset Failed" "$display"
    silent_log "Failed to reset password for: $username - no hashing method available"
  fi
}

deactivate_user_interactive() {
  local input username result display
  input=$(ui_input "Deactivate User" "Enter username to deactivate:" "")
  if [[ -z "$input" ]]; then
    ui_msg "Cancelled" "No username provided"
    return
  fi

  username=$(normalize_username "$input")

  if ! confirm "Deactivate (soft delete) user '$username'? This will disable the account."; then
    ui_msg "Cancelled" "Deactivation cancelled"
    return
  fi

  local update_query="UPDATE users SET deactivated=1 WHERE name='$username';"
  result=$(execute_query "$update_query" 2>&1 || echo "Error deactivating user")
  display=$(printf "Deactivated user: %s\n\nResult:\n%s\n" "$username" "$result")
  show_results "User Deactivated" "$display"
  silent_log "Deactivated user: $username"
}

reactivate_user_interactive() {
  local input username result display
  input=$(ui_input "Reactivate User" "Enter username to reactivate:" "")
  if [[ -z "$input" ]]; then
    ui_msg "Cancelled" "No username provided"
    return
  fi

  username=$(normalize_username "$input")

  if ! confirm "Reactivate user '$username'?"; then
    ui_msg "Cancelled" "Reactivation cancelled"
    return
  fi

  local update_query="UPDATE users SET deactivated=0 WHERE name='$username';"
  result=$(execute_query "$update_query" 2>&1 || echo "Error reactivating user")
  display=$(printf "Reactivated user: %s\n\nResult:\n%s\n" "$username" "$result")
  show_results "User Reactivated" "$display"
  silent_log "Reactivated user: $username"
}

backup_database() {
  silent_log "Starting database backup..."
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')

  if [[ "$DB_TYPE" == "postgres" ]]; then
    local backup_file="${SCRIPT_DIR}/synapse_postgres_backup_${timestamp}.sql"
    if docker exec "$POSTGRES_CONTAINER" env PGPASSWORD="$PG_PASS" pg_dump -U "$PG_USER" "$PG_DB" > "$backup_file" 2>/dev/null; then
      local size
      size=$(du -h "$backup_file" | cut -f1)
      local display
      display=$(printf "PostgreSQL backup saved to:\n%s\n\nSize: %s\n" "$backup_file" "$size")
      show_results "Backup Complete" "$display"
      silent_log "Backup saved to: $backup_file"
    else
      show_results "Backup Failed" "Failed to create PostgreSQL backup"
      silent_log "Backup failed"
    fi
  else
    local backup_file="${SCRIPT_DIR}/synapse_sqlite_backup_${timestamp}.db"
    local temp_path="/tmp/backup_${timestamp}.db"

    if docker exec "$SYNAPSE_CONTAINER" cp "$SQLITE_PATH" "$temp_path" 2>/dev/null && \
       docker cp "${SYNAPSE_CONTAINER}:${temp_path}" "$backup_file" 2>/dev/null; then
      docker exec "$SYNAPSE_CONTAINER" rm -f "$temp_path" 2>/dev/null || true
      local size
      size=$(du -h "$backup_file" | cut -f1)
      local display
      display=$(printf "SQLite backup saved to:\n%s\n\nSize: %s\n" "$backup_file" "$size")
      show_results "Backup Complete" "$display"
      silent_log "Backup saved to: $backup_file"
    else
      show_results "Backup Failed" "Failed to create SQLite backup"
      silent_log "Backup failed"
    fi
  fi
}

run_custom_query() {
  local sql result display
  sql=$(ui_input "Custom Query" "Enter SQL query:" "SELECT name, admin, deactivated FROM users LIMIT 10;")
  if [[ -z "$sql" ]]; then
    ui_msg "Cancelled" "No query provided"
    return
  fi

  if ! confirm "Execute this SQL query?\n\n$sql"; then
    ui_msg "Cancelled" "Query execution cancelled"
    return
  fi

  result=$(execute_query "$sql" 2>&1 || echo "Query execution failed")
  display=$(printf "%s\n" "$result")
  show_results "Query Results" "$display"
  silent_log "Executed custom query: $sql"
}

# ---------- MENU LOOP ----------
main_menu() {
  while true; do
    local choice
    choice=$(ui_menu "Matrix User Manager" "Select an action:" \
      "0" "Exit" \
      "1" "List all users" \
      "2" "Show user information" \
      "3" "Create new user" \
      "4" "Reset user password" \
      "5" "Deactivate (disable) user" \
      "6" "Reactivate (enable) user" \
      "7" "Backup database" \
      "8" "Run custom SQL query"
    )

    # Handle invalid choices in fallback mode
    if [[ -z "$choice" ]]; then
      continue
    fi

    case "$choice" in
      "0") break ;;
      "1") list_users ;;
      "2") show_user_info ;;
      "3") create_user_interactive ;;
      "4") reset_password_interactive ;;
      "5") deactivate_user_interactive ;;
      "6") reactivate_user_interactive ;;
      "7") backup_database ;;
      "8") run_custom_query ;;
      *) continue ;;
    esac
  done
}

# ---------- ENTRY ----------
main() {
  echo "Starting Matrix User Manager..."
  
  check_requirements
  setup_ui
  detect_containers
  detect_database_config

  # Show welcome message AFTER all configuration is done
  echo -e "${CYAN}=== Matrix User Manager ===${NC}"
  local welcome_msg="Welcome to Matrix User Manager

Configuration detected:
• Synapse container: $SYNAPSE_CONTAINER
• Database type: $DB_TYPE"
  
  if [[ "$DB_TYPE" == "postgres" ]]; then
    welcome_msg+="
• Postgres container: $POSTGRES_CONTAINER  
• Database: $PG_USER@$PG_HOST:$PG_PORT/$PG_DB"
  else
    welcome_msg+="
• SQLite path: $SQLITE_PATH"
  fi
  
  welcome_msg+="
• Domain: $DOMAIN
• Config: $HOMESERVER_YAML_PATH
• Log file: $LOGFILE"

  show_results "Configuration Complete" "$welcome_msg"
  
  log "=== Matrix User Manager Started ==="
  log "Synapse: $SYNAPSE_CONTAINER, DB: $DB_TYPE, Domain: $DOMAIN"
  
  
  main_menu
  log "=== Matrix User Manager Ended ==="
}

# Run main function
main "$@"
