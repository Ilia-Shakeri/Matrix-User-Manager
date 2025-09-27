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
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="${SCRIPT_DIR}/${SCRIPT_NAME%.*}.log"
TMPDIR="/tmp/${SCRIPT_NAME%.*}.$$"
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

detect_package_manager_in_container() {
  # param: container name
  local cont="$1"
  if docker exec "$cont" sh -c 'command -v apt-get >/dev/null 2>&1' 2>/dev/null; then
    echo "apt"
  elif docker exec "$cont" sh -c 'command -v apk >/dev/null 2>&1' 2>/dev/null; then
    echo "apk"
  elif docker exec "$cont" sh -c 'command -v yum >/dev/null 2>&1' 2>/dev/null; then
    echo "yum"
  else
    echo "unknown"
  fi
}

setup_ui() {
  USE_WHIPTAIL=false
  if command -v whiptail >/dev/null 2>&1; then
    USE_WHIPTAIL=true
    return
  fi
  echo -e "${YELLOW}Whiptail not found. This tool provides a better UI.${NC}"
  echo -e "${CYAN}Would you like to install whiptail for better UI? [Y/n]:${NC}"
  read -r response || true
  if [[ -z "$response" || "$response" =~ ^[Yy] ]]; then
    if [[ $EUID -ne 0 ]]; then
      echo -e "${YELLOW}Need root to auto-install. Continuing with text UI...${NC}"
      return
    fi
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y whiptail || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y newt || true
    else
      echo -e "${YELLOW}Auto-install not supported on this host. Install whiptail manually.${NC}"
    fi
    if command -v whiptail >/dev/null 2>&1; then
      USE_WHIPTAIL=true
      return
    fi
  fi
  echo -e "${CYAN}Continuing with text-based interface...${NC}"
}

ui_msg() {
  local title="${1:-Message}"
  local text="${2:-}"
  if $USE_WHIPTAIL; then
    whiptail --title "$title" --msgbox "$text" 20 100
  else
    echo -e "${CYAN}=== $title ===${NC}" >&2
    echo -e "$text" >&2
    echo -e "${YELLOW}Press Enter to continue...${NC}" >&2
    read -r
  fi
}

ui_input() {
  local title="$1"; local prompt="$2"; local default="${3:-}"
  if $USE_WHIPTAIL; then
    whiptail --title "$title" --inputbox "$prompt" 12 70 "$default" 3>&1 1>&2 2>&3
  else
    echo -e "${CYAN}$title${NC}" >&2
    if [[ -n "$default" ]]; then
      printf "%s" "$prompt [$default]: " >&2
    else
      printf "%s" "$prompt: " >&2
    fi
    read -r val
    echo "${val:-$default}"
  fi
}

ui_password() {
  local title="$1"; local prompt="$2"
  if $USE_WHIPTAIL; then
    whiptail --title "$title" --passwordbox "$prompt" 12 70 3>&1 1>&2 2>&3
  else
    echo -e "${CYAN}$title${NC}" >&2
    printf "%s" "$prompt: " >&2
    read -rs val
    echo "" >&2
    echo "$val"
  fi
}

ui_menu() {
  local title="$1"; shift
  local prompt="$1"; shift
  if $USE_WHIPTAIL; then
    whiptail --title "$title" --menu "$prompt" 20 100 12 --default-item "0" "$@" 3>&1 1>&2 2>&3
  else
    local -a menu_items=("$@")
    while true; do
      echo "" >&2
      echo -e "${CYAN}=== $title ===${NC}" >&2
      echo "$prompt" >&2
      echo "" >&2
      local i=0
      while (( i < ${#menu_items[@]} )); do
        local option_key="${menu_items[$i]}"
        local option_desc="${menu_items[$((i+1))]}"
        echo "$option_key) $option_desc" >&2
        i=$((i+2))
      done
      echo "" >&2
      echo -n "Choose (enter number): " >&2
      read -r choice
      choice="${choice##[ \t]*}"
      choice="${choice%%[ \t]*}"
      if [[ -z "$choice" ]]; then
        echo -e "${YELLOW}Please enter a number.${NC}" >&2
        continue
      fi
      i=0
      while (( i < ${#menu_items[@]} )); do
        if [[ "${menu_items[$i]}" == "$choice" ]]; then
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
    if whiptail --title "Confirm" --yesno "$prompt" 8 70; then return 0; else return 1; fi
  else
    echo -e "${YELLOW}$prompt${NC}" >&2
    read -r -p "[y/N]: " y
    [[ $y =~ ^[Yy] ]] && return 0 || return 1
  fi
}

# Format CSV to aligned table (uses `column` if available, else falls back to raw)
format_table() {
  local raw="$1"
  # strip CR (\r) first to remove ^M, then column
  if command -v column >/dev/null 2>&1; then
    printf "%s\n" "$raw" | sed -e 's/\r$//' | column -t -s',' || printf "%s\n" "$raw" | sed -e 's/\r$//'
  else
    printf "%s\n" "$raw" | sed -e 's/\r$//'
  fi
}

show_results() {
  local title="$1"
  local content="$2"
  if [[ -z "${content//[$'\n\r\t ']}" ]]; then
    content="(no results)"
  fi
  # strip CR from content
  content="$(printf '%s\n' "$content" | sed -e 's/\r$//')"

  local firstline
  firstline="$(printf '%s\n' "$content" | sed -n '1p')"
  if [[ "$firstline" == *","* ]]; then
    content="$(format_table "$content")"
  fi

  if $USE_WHIPTAIL; then
    whiptail --title "$title" --msgbox "$content" 20 120 --scrolltext
  else
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
HOMESERVER_CONTENT=""
DOMAIN=""
DB_TYPE=""
SQLITE_PATH=""
PG_USER=""
PG_DB=""
PG_HOST=""
PG_PORT=""
PG_PASS=""

detect_containers() {
  silent_log "Starting container detection..."
  local syns
  syns=$(docker ps --format "{{.Names}}\t{{.Image}}" | grep -iE "(synapse|matrix)" | grep -v postgres | grep -v nginx | grep -v coturn | grep -v element || true)
  if [[ -z "$syns" ]]; then
    syns=$(docker ps --format "{{.Names}}\t{{.Image}}" | grep -iE "synapse" || true)
  fi
  if [[ -n "$syns" ]]; then
    if [[ $(echo "$syns" | wc -l) -eq 1 ]]; then
      SYNAPSE_CONTAINER=$(echo "$syns" | awk '{print $1}')
      silent_log "Auto-detected single synapse container: $SYNAPSE_CONTAINER"
    else
      echo "" >&2
      echo "Multiple Matrix/Synapse containers found:" >&2
      local i=1
      while IFS=$'\t' read -r name image; do
        echo "$i) $name ($image)" >&2
        i=$((i+1))
      done <<< "$syns"
      echo "" >&2
      local containers=()
      while IFS=$'\t' read -r name image; do
        containers+=("$name" "$image")
      done <<< "$syns"
      local choice
      if $USE_WHIPTAIL; then
        choice=$(ui_menu "Select Synapse Container" "Multiple Matrix/Synapse containers found:" "${containers[@]}")
      else
        while true; do
          read -r -p "Choose container (enter number 1-$(echo "$syns" | wc -l) or container name): " choice
          if [[ "$choice" =~ ^[0-9]+$ ]]; then
            line_num=$choice
            if [[ $line_num -gt 0 && $line_num -le $(echo "$syns" | wc -l) ]]; then
              choice=$(echo "$syns" | sed -n "${line_num}p" | awk '{print $1}')
              break
            else
              echo "Invalid"
            fi
          else
            if echo "$syns" | grep -q "^$choice[[:space:]]"; then
              break
            fi
          fi
        done
      fi
      SYNAPSE_CONTAINER="$choice"
      silent_log "User selected synapse container: $SYNAPSE_CONTAINER"
    fi
  fi

  local pgs
  pgs=$(docker ps --format "{{.Names}}\t{{.Image}}" | grep -iE "postgres|postgresql" || true)
  if [[ -n "$pgs" ]]; then
    if [[ $(echo "$pgs" | wc -l) -eq 1 ]]; then
      POSTGRES_CONTAINER=$(echo "$pgs" | awk '{print $1}')
      silent_log "Auto-detected single postgres container: $POSTGRES_CONTAINER"
    else
      echo "Multiple Postgres containers found:" >&2
      echo "0) Skip - Use SQLite" >&2
      local i=1
      while IFS=$'\t' read -r name image; do
        echo "$i) $name ($image)" >&2
        i=$((i+1))
      done <<< "$pgs"
      local containers=("skip" "Skip - Use SQLite")
      while IFS=$'\t' read -r name image; do
        containers+=("$name" "$image")
      done <<< "$pgs"
      local choice
      if $USE_WHIPTAIL; then
        choice=$(ui_menu "Select Postgres Container" "Multiple Postgres containers found (or skip for SQLite):" "${containers[@]}")
      else
        while true; do
          read -r -p "Choose (0 to skip): " choice
          if [[ "$choice" == "0" ]]; then
            choice="skip"; break
          fi
          if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [[ $choice -ge 1 && $choice -le $(echo "$pgs" | wc -l) ]]; then
              choice=$(echo "$pgs" | sed -n "${choice}p" | awk '{print $1}')
              break
            fi
          else
            if echo "$pgs" | grep -q "^$choice[[:space:]]"; then break; fi
          fi
        done
      fi
      if [[ "$choice" != "skip" && -n "$choice" ]]; then
        POSTGRES_CONTAINER="$choice"
        silent_log "User selected postgres container: $POSTGRES_CONTAINER"
      fi
    fi
  fi

  if [[ -z "$SYNAPSE_CONTAINER" ]]; then
    local all_containers
    all_containers=$(docker ps --format "{{.Names}}\t{{.Image}}" || true)
    echo -e "${CYAN}Available containers:${NC}" >&2
    echo "$all_containers" >&2
    SYNAPSE_CONTAINER=$(ui_input "Synapse Container" "Enter container name:" "")
    if [[ -z "$SYNAPSE_CONTAINER" ]]; then
      ui_msg "Error" "Synapse container required"
      exit 1
    fi
  fi
  silent_log "Final containers - Synapse: $SYNAPSE_CONTAINER, Postgres: ${POSTGRES_CONTAINER:-none}"
}

debug_sqlite() {
  docker exec -e SQLITE_DB_PATH="$SQLITE_PATH" "$SYNAPSE_CONTAINER" python3 - <<'PY'
import sqlite3,os
db = os.environ.get('SQLITE_DB_PATH','/data/homeserver.db')
print("Using DB:", db)
conn = sqlite3.connect(db)
cur = conn.cursor()
cur.execute("SELECT COUNT(*) FROM users;")
print("users:", cur.fetchone()[0])
conn.close()
PY
}

read_homeserver_yaml() {
  if [[ -z "$SYNAPSE_CONTAINER" ]]; then
    ui_msg "Error" "No Synapse container selected."
    exit 1
  fi
  local possible_paths=( "/data/homeserver.yaml" "/data/synapse/homeserver.yaml" "/etc/matrix-synapse/homeserver.yaml" "/app/homeserver.yaml" "/synapse/config/homeserver.yaml" "/synapse/data/homeserver.yaml" "/config/homeserver.yaml" )
  HOMESERVER_YAML_PATH=""
  for p in "${possible_paths[@]}"; do
    if docker exec "$SYNAPSE_CONTAINER" test -f "$p" 2>/dev/null; then
      HOMESERVER_YAML_PATH="$p"; break
    fi
  done
  if [[ -z "$HOMESERVER_YAML_PATH" ]]; then
    local found
    found=$(docker exec "$SYNAPSE_CONTAINER" find / -name "homeserver.yaml" -type f 2>/dev/null | head -10 || true)
    if [[ -n "$found" ]]; then
      HOMESERVER_YAML_PATH=$(ui_input "Homeserver Config" "Enter path to homeserver.yaml inside the container:" "$(echo "$found" | head -n1)")
    else
      HOMESERVER_YAML_PATH=$(ui_input "Homeserver Config" "Enter path to homeserver.yaml inside the container:" "/data/homeserver.yaml")
    fi
  fi
  HOMESERVER_CONTENT=$(docker exec "$SYNAPSE_CONTAINER" cat "$HOMESERVER_YAML_PATH" 2>/dev/null || echo "")
  if [[ -z "$HOMESERVER_CONTENT" ]]; then
    ui_msg "Error" "Unable to read homeserver.yaml from container '$SYNAPSE_CONTAINER' at path '$HOMESERVER_YAML_PATH'"
    exit 1
  fi
  DOMAIN=$(echo "$HOMESERVER_CONTENT" | grep -E "^server_name:" | head -n1 | sed 's/server_name:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d ' ' || true)
  DOMAIN="${DOMAIN:-matrix.example.com}"
  silent_log "Found homeserver.yaml at: $HOMESERVER_YAML_PATH"
  silent_log "Domain: $DOMAIN"
  echo -e "${GREEN}Successfully read homeserver.yaml${NC}" >&2
  echo -e "${CYAN}Domain: $DOMAIN${NC}" >&2
  echo -e "${CYAN}Config path: $HOMESERVER_YAML_PATH${NC}" >&2
}

detect_database_config() {
  if [[ -z "$HOMESERVER_CONTENT" ]]; then
    ui_msg "Error" "homeserver.yaml not loaded. Cannot detect database configuration."
    exit 1
  fi
  DB_TYPE=""; SQLITE_PATH=""; PG_USER=""; PG_DB=""; PG_HOST=""; PG_PORT=""; PG_PASS=""
  echo "=== Database section from homeserver.yaml ===" >> "$LOGFILE"
  echo "$HOMESERVER_CONTENT" | sed -n '/^database:/,/^[a-zA-Z]/p' >> "$LOGFILE"
  echo "=============================================" >> "$LOGFILE"
  
  if echo "$HOMESERVER_CONTENT" | grep -q "name: sqlite3\|name: \"sqlite3\"\|name: 'sqlite3'"; then
    DB_TYPE="sqlite"
    # try multiple parsers
    SQLITE_PATH=$(echo "$HOMESERVER_CONTENT" | sed -n '/name: sqlite3/,/^[^ ]/p' | grep "database:" | sed 's/.*database:[[:space:]]*//' | tr -d '"' | tr -d "'" | head -n1 || true)
    SQLITE_PATH="${SQLITE_PATH:-/data/homeserver.db}"
    echo -e "${GREEN}Detected SQLite database${NC}" >&2
    echo -e "${CYAN}SQLite path: $SQLITE_PATH${NC}" >&2
    silent_log "Detected database type: sqlite, path: $SQLITE_PATH"
  elif echo "$HOMESERVER_CONTENT" | grep -q "name: psycopg2\|name: \"psycopg2\"\|name: 'psycopg2'"; then
    DB_TYPE="postgres"
    local db_section
    db_section=$(echo "$HOMESERVER_CONTENT" | sed -n '/^database:/,/^[a-zA-Z]/p')
    PG_USER=$(echo "$db_section" | grep -E "^[[:space:]]*user:" | sed 's/.*user:[[:space:]]*//' | tr -d '"' | tr -d "'" | head -n1)
    PG_PASS=$(echo "$db_section" | grep -E "^[[:space:]]*password:" | sed 's/.*password:[[:space:]]*//' | tr -d '"' | tr -d "'" | head -n1)
    PG_HOST=$(echo "$db_section" | grep -E "^[[:space:]]*host:" | sed 's/.*host:[[:space:]]*//' | tr -d '"' | tr -d "'" | head -n1)
    PG_PORT=$(echo "$db_section" | grep -E "^[[:space:]]*port:" | sed 's/.*port:[[:space:]]*//' | tr -d '"' | tr -d "'" | head -n1)
    PG_DB=$(echo "$db_section" | grep -E "^[[:space:]]*(database|dbname):" | sed 's/.*\(database\|dbname\):[[:space:]]*//' | tr -d '"' | tr -d "'" | head -n1)
    PG_USER="${PG_USER:-synapse}"; PG_DB="${PG_DB:-synapse}"; PG_HOST="${PG_HOST:-localhost}"; PG_PORT="${PG_PORT:-5432}"
    echo -e "${CYAN}PostgreSQL config: ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}${NC}" >&2
    silent_log "Detected database type: postgres, config: $PG_USER@$PG_HOST:$PG_PORT/$PG_DB"
  else
    echo -e "${YELLOW}Could not automatically determine database type from homeserver.yaml${NC}" >&2
    local choice
    choice=$(ui_menu "Database Type" "Choose database type:" "sqlite" "SQLite (homeserver.db file)" "postgres" "PostgreSQL database")
    if [[ "$choice" == "sqlite" ]]; then
      DB_TYPE="sqlite"; SQLITE_PATH="/data/homeserver.db"
    else
      DB_TYPE="postgres"; PG_USER="synapse"; PG_DB="synapse"; PG_HOST="localhost"; PG_PORT="5432"
    fi
  fi

  if [[ "$DB_TYPE" == "sqlite" ]]; then
    echo -e "${CYAN}Setting up SQLite database access...${NC}" >&2
    local possible_paths=("$SQLITE_PATH" "/data/homeserver.db" "/app/homeserver.db" "/synapse/data/homeserver.db")
    local found_path=""
    for path in "${possible_paths[@]}"; do
      if docker exec "$SYNAPSE_CONTAINER" test -f "$path" 2>/dev/null; then
        found_path="$path"; break
      fi
    done
    if [[ -z "$found_path" ]]; then
      local found_dbs
      found_dbs=$(docker exec "$SYNAPSE_CONTAINER" find / -name "*.db" -type f 2>/dev/null | grep -v "/proc/" | head -10 || true)
      if [[ -n "$found_dbs" ]]; then
        SQLITE_PATH=$(ui_input "SQLite Database" "Enter SQLite database path:" "$(echo "$found_dbs" | head -n1)")
      else
        SQLITE_PATH=$(ui_input "SQLite Database" "Enter SQLite database path:" "/data/homeserver.db")
      fi
    else
      SQLITE_PATH="$found_path"
    fi

    # Test access: prefer python-based check (sqlite3 binary may be missing)
    if docker exec "$SYNAPSE_CONTAINER" sh -c "command -v python3 >/dev/null 2>&1"; then
      if docker exec -e TEST_DB="$SQLITE_PATH" "$SYNAPSE_CONTAINER" python3 - <<'PY' >/dev/null 2>&1
import os, sqlite3, sys
db = os.environ.get("TEST_DB","")
try:
    conn=sqlite3.connect(db)
    conn.execute("SELECT name FROM sqlite_master WHERE type='table' LIMIT 1;")
    conn.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
      then
        echo -e "${GREEN}SQLite database access confirmed (via python3 sqlite module)${NC}" >&2
        silent_log "SQLite database access verified (python3): $SQLITE_PATH"
      else
        ui_msg "Error" "python3 is present in container but cannot open SQLite DB at '$SQLITE_PATH'. Check path and file permissions inside container."
        exit 1
      fi
    else
      ui_msg "Error" "Cannot access SQLite database at '$SQLITE_PATH' in container '$SYNAPSE_CONTAINER': python3 not available inside container."
      exit 1
    fi

    # Check if sqlite3 command is available on host (needed for write operations)
    if ! command -v sqlite3 >/dev/null 2>&1; then
      echo -e "${YELLOW}sqlite3 command not found on host. Required for safe SQLite writes.${NC}" >&2
      if confirm "Install sqlite3 on host (requires sudo/root)?"; then
        if command -v apt-get >/dev/null 2>&1; then
          sudo apt-get update && sudo apt-get install -y sqlite3
        elif command -v apk >/dev/null 2>&1; then
          sudo apk add --no-cache sqlite
        elif command -v yum >/dev/null 2>&1; then
          sudo yum install -y sqlite
        else
          ui_msg "Error" "Auto-install not supported. Install sqlite3 manually on host."
          exit 1
        fi
      else
        ui_msg "Error" "sqlite3 required for SQLite operations. Install manually."
        exit 1
      fi
    fi
  fi

  if [[ "$DB_TYPE" == "postgres" ]]; then
    if [[ -z "$POSTGRES_CONTAINER" ]]; then
      ui_msg "Error" "PostgreSQL configuration detected but no Postgres container found."
      exit 1
    fi
    if [[ -z "$PG_PASS" ]]; then
      PG_PASS=$(ui_password "PostgreSQL Password" "Enter PostgreSQL password for user '$PG_USER' on database '$PG_DB':")
      if [[ -z "$PG_PASS" ]]; then ui_msg "Error" "PostgreSQL password required"; exit 1; fi
    fi
    if docker exec "$POSTGRES_CONTAINER" env PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1;" >/dev/null 2>&1; then
      echo -e "${GREEN}PostgreSQL database access confirmed${NC}" >&2
      silent_log "Postgres connection verified"
    else
      ui_msg "Error" "Cannot connect to PostgreSQL database. Check credentials and ensure container is running."
      exit 1
    fi
  fi

  echo -e "${GREEN}Database configuration completed successfully!${NC}" >&2
  silent_log "Database configuration complete - Type: $DB_TYPE"
}

# ---------- DB EXECUTION HELPERS ----------
exec_psql() {
  local sql="$1"
  docker exec "$POSTGRES_CONTAINER" env PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -d "$PG_DB" -c "$sql"
}

exec_sqlite() {
  local sql="$1"
  # Write SQL to temp file to avoid shell escaping issues
  echo "$sql" > "$TMPDIR/query.sql"
  # Copy into container
  docker cp "$TMPDIR/query.sql" "$SYNAPSE_CONTAINER:/tmp/query.sql"
  # Run python inside container to execute the SQL (use -i so heredoc works)
  docker exec -i -e SQLITE_DB_PATH="$SQLITE_PATH" "$SYNAPSE_CONTAINER" python3 - <<'PY'
import os, sqlite3, sys, csv
try:
    db = os.environ.get("SQLITE_DB_PATH", "/data/homeserver.db")
    with open('/tmp/query.sql','r') as f:
        sql = f.read().strip()
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute(sql)
    rows = cur.fetchall()
    cols = [d[0] for d in cur.description] if cur.description else []
    w = csv.writer(sys.stdout)
    if cols:
        w.writerow(cols)
    for r in rows:
        w.writerow([("" if x is None else str(x)) for x in r])
    conn.close()
    try:
        os.remove('/tmp/query.sql')
    except Exception:
        pass
except Exception as e:
    sys.stderr.write("SQLite Error: " + str(e) + "\n")
    sys.exit(1)
PY
}

execute_query() {
  local sql="$1"
  if [[ "$DB_TYPE" == "postgres" ]]; then
    exec_psql "$sql"
  else
    exec_sqlite "$sql"
  fi
}

safe_write_query() {
  local sql="$1"
  local result=""
  if [[ "$DB_TYPE" == "postgres" ]]; then
    result=$(exec_psql "$sql" 2>&1) || result="Postgres Error: $result"
  else  # SQLite
    if confirm "SQLite detected. To perform writes, the script needs to temporarily stop the Synapse container (brief downtime) and copy DB to host for update. Proceed?"; then
      # Capture original ownership before stop
      original_owner=$(docker exec "$SYNAPSE_CONTAINER" stat -c '%u:%g' "$SQLITE_PATH" 2>&1) || { ui_msg "Error" "Failed to get original DB ownership: $original_owner"; return 1; }
      echo -e "${CYAN}Stopping Synapse container...${NC}" >&2
      docker stop "$SYNAPSE_CONTAINER" >/dev/null 2>&1 || { ui_msg "Error" "Failed to stop container."; return 1; }
      sleep 2  # Brief delay to ensure locks release
      local tmp_db="$TMPDIR/homeserver.db"
      docker cp "$SYNAPSE_CONTAINER:$SQLITE_PATH" "$tmp_db" 2>&1 || { ui_msg "Error" "Failed to copy DB from container."; docker start "$SYNAPSE_CONTAINER" >/dev/null 2>&1; return 1; }
      # Execute write on host with sqlite3 (captures detailed errors)
      result=$(sqlite3 "$tmp_db" "$sql" 2>&1)
      if [[ $? -ne 0 ]]; then
        result="SQLite Write Error: $result\nTip: Check if DB is in WAL mode (common in Synapse) and host sqlite3 supports it. Manual fix: Ensure sufficient disk space and no file locks."
      else
        result="Update successful."
      fi
      # Copy back only if successful
      if [[ ! "$result" =~ "Error" ]]; then
        docker cp "$tmp_db" "$SYNAPSE_CONTAINER:$SQLITE_PATH" 2>&1 || { ui_msg "Error" "Failed to copy DB back to container."; docker start "$SYNAPSE_CONTAINER" >/dev/null 2>&1; return 1; }
        # Restore original ownership using temporary busybox container (Docker auto-pulls if missing)
        chown_result=$(docker run --rm --user 0 --volumes-from "$SYNAPSE_CONTAINER" busybox chown "$original_owner" "$SQLITE_PATH" 2>&1) || { ui_msg "Error" "Failed to restore DB ownership: $chown_result\nTip: Ensure Docker can pull 'busybox' (tiny image). If fails, install busybox on host or manually chown inside container after start."; return 1; }
      fi
      rm -f "$tmp_db"  # Clean up
      echo -e "${CYAN}Starting Synapse container...${NC}" >&2
      docker start "$SYNAPSE_CONTAINER" >/dev/null 2>&1 || { ui_msg "Error" "Failed to start container."; return 1; }
      if ! docker inspect -f '{{.State.Running}}' "$SYNAPSE_CONTAINER" | grep -q 'true'; then
        ui_msg "Error" "Container failed to start. Check docker logs: docker logs $SYNAPSE_CONTAINER"
        return 1
      fi
#  Optional: Tail recent logs for startup errors
start_logs=$(docker logs --tail 20 "$SYNAPSE_CONTAINER" 2>&1)
if echo "$start_logs" | grep -iq "error\|exception\|readonly"; then
  ui_msg "Warning" "Potential startup error detected in logs:\n$start_logs\nTip: If read-only DB persists, manually verify permissions inside container: docker exec -u root $SYNAPSE_CONTAINER chown <original_uid:gid> $SQLITE_PATH"
fi
      sleep 5  # Brief delay to let Synapse start; optional but helps verification
    else
      ui_msg "Cancelled" "Write operation cancelled due to potential DB lock."
      return 1
    fi
  fi
  echo "$result"
}

normalize_username() {
  local input="$1"; local username
  if [[ "$input" =~ ^@.*:.* ]]; then username="$input"
  elif [[ "$input" =~ ^@ ]]; then username="${input}:${DOMAIN}"
  else username="@${input}:${DOMAIN}"; fi 
  echo "$username"
}

escape_sql() {
  local input="$1"
  echo "${input//\'/\'\'}"
}

# ---------- ACTIONS ----------
list_users() {
  silent_log "Listing users..."
  local query result
  if [[ "$DB_TYPE" == "postgres" ]]; then
    query="SELECT name AS username, CASE WHEN admin = 1 THEN 'YES' ELSE 'NO' END AS admin, CASE WHEN deactivated = 1 THEN 'YES' ELSE 'NO' END AS deactivated, to_timestamp(creation_ts) AS created FROM users ORDER BY creation_ts DESC LIMIT 100;"
  else
    # handle both ms and s timestamps
    query="SELECT name AS username, CASE WHEN admin = 1 THEN 'YES' ELSE 'NO' END AS admin, CASE WHEN deactivated = 1 THEN 'YES' ELSE 'NO' END AS deactivated, CASE WHEN creation_ts>100000000000 THEN datetime(creation_ts/1000,'unixepoch') ELSE datetime(creation_ts,'unixepoch') END AS created FROM users ORDER BY creation_ts DESC LIMIT 100;"
  fi
  result=$(execute_query "$query" 2>&1 || echo "Error: Could not retrieve users")
  show_results "Users List" "$result"
  silent_log "Listed users successfully"
}

show_user_info() {
  local input username user_query device_query room_query user_info devices rooms display
  input=$(ui_input "User Info" "Enter username (we'll add @ and domain if needed):" "")
  if [[ -z "$input" ]]; then ui_msg "Cancelled" "No username provided"; return; fi
  username=$(normalize_username "$input")

  if [[ "$DB_TYPE" == "postgres" ]]; then
    user_query="SELECT name, CASE WHEN admin = 1 THEN 'YES' ELSE 'NO' END AS admin, CASE WHEN deactivated = 1 THEN 'YES' ELSE 'NO' END AS deactivated, to_timestamp(creation_ts) AS created, user_type FROM users WHERE name='${username}';"
    device_query="SELECT device_id, display_name, to_timestamp(last_seen/1000) AS last_seen FROM devices WHERE user_id='${username}' ORDER BY last_seen DESC LIMIT 10;"
  else
    user_query="SELECT name, CASE WHEN admin = 1 THEN 'YES' ELSE 'NO' END AS admin, CASE WHEN deactivated = 1 THEN 'YES' ELSE 'NO' END AS deactivated, CASE WHEN creation_ts>100000000000 THEN datetime(creation_ts/1000,'unixepoch') ELSE datetime(creation_ts,'unixepoch') END AS created, user_type FROM users WHERE name='${username}';"
    device_query="SELECT device_id, display_name, CASE WHEN last_seen>100000000000 THEN datetime(last_seen/1000,'unixepoch') ELSE datetime(last_seen,'unixepoch') END AS last_seen FROM devices WHERE user_id='${username}' ORDER BY last_seen DESC LIMIT 10;"
  fi
  room_query="SELECT room_id, membership FROM room_memberships WHERE user_id='${username}' AND membership IN ('join','invite') LIMIT 20;"

  user_info=$(execute_query "$user_query" 2>&1 || echo "Error getting user info")
  devices=$(execute_query "$device_query" 2>&1 || echo "No devices found")
  rooms=$(execute_query "$room_query" 2>&1 || echo "No room memberships found")

  display=$(printf "=== USER INFORMATION ===\n%s\n\n=== USER DEVICES ===\n%s\n\n=== ROOM MEMBERSHIPS ===\n%s\n" "$user_info" "$devices" "$rooms")
  show_results "User Info: $username" "$display"
  silent_log "Showed info for user: $username"
}



_try_hash_on_host() {
  local pass="$1"
  local hashed=""
  if command -v python3 >/dev/null 2>&1; then
    hashed=$(python3 - <<PY 2>/tmp/.bcrypt_err_host.$$
import bcrypt,sys
p = sys.argv[1].encode('utf-8')
try:
    print(bcrypt.hashpw(p, bcrypt.gensalt()).decode('utf-8'))
except Exception as e:
    sys.stderr.write("ERR:"+str(e))
    sys.exit(2)
PY
"$pass" 2>/dev/null || true)
    if [[ -s /tmp/.bcrypt_err_host.$$ ]]; then
      silent_log "bcrypt (host) stderr: $(sed -n '1,200p' /tmp/.bcrypt_err_host.$$)"
    fi
    rm -f /tmp/.bcrypt_err_host.$$ || true
  fi
  echo "$hashed"
}

_try_hash_synapse_native() {
  local pass="$1"
  local hashed=""
  # Write password to temp file to avoid shell escaping issues
  echo -n "$pass" > "$TMPDIR/temp_pass_synapse.txt"
  docker cp "$TMPDIR/temp_pass_synapse.txt" "$SYNAPSE_CONTAINER:/tmp/temp_pass_synapse.txt"
  
  # Try Synapse's built-in hash_password script first
  if docker exec "$SYNAPSE_CONTAINER" sh -c "command -v hash_password >/dev/null 2>&1"; then
    hashed=$(docker exec "$SYNAPSE_CONTAINER" sh -c "cat /tmp/temp_pass_synapse.txt | hash_password" 2>/dev/null || echo "")
  elif docker exec "$SYNAPSE_CONTAINER" sh -c "python3 -m synapse.util.hash_password --help >/dev/null 2>&1"; then
    hashed=$(docker exec "$SYNAPSE_CONTAINER" sh -c "cat /tmp/temp_pass_synapse.txt | python3 -m synapse.util.hash_password" 2>/dev/null || echo "")
  elif docker exec "$SYNAPSE_CONTAINER" sh -c "find /usr -name 'hash_password*' -executable 2>/dev/null | head -1" | read -r hash_script && [[ -n "$hash_script" ]]; then
    hashed=$(docker exec "$SYNAPSE_CONTAINER" sh -c "cat /tmp/temp_pass_synapse.txt | '$hash_script'" 2>/dev/null || echo "")
  fi
  
  # Clean up temp file
  docker exec "$SYNAPSE_CONTAINER" rm -f /tmp/temp_pass_synapse.txt 2>/dev/null || true
  rm -f "$TMPDIR/temp_pass_synapse.txt" 2>/dev/null || true
  echo "$hashed"
}

_try_hash_in_container() {
  local pass="$1"
  local hashed=""
  # Write password to temp file and read inside container
  echo -n "$pass" > "$TMPDIR/temp_pass.txt"
  docker cp "$TMPDIR/temp_pass.txt" "$SYNAPSE_CONTAINER:/tmp/temp_pass.txt"
  {
    hashed=$(docker exec "$SYNAPSE_CONTAINER" python3 - <<'PY' 2>/tmp/.bcrypt_err.$$
import bcrypt,sys
try:
    with open('/tmp/temp_pass.txt','r') as f:
        pw = f.read().encode("utf-8")
    print(bcrypt.hashpw(pw, bcrypt.gensalt()).decode("utf-8"))
except Exception as e:
    sys.stderr.write("ERR:"+str(e))
    sys.exit(2)
finally:
    try:
        import os
        os.remove('/tmp/temp_pass.txt')
    except:
        pass
PY
)
  }
  # capture stderr if any for logging
  if [[ -s /tmp/.bcrypt_err.$$ ]]; then
    silent_log "bcrypt (container) stderr: $(sed -n '1,200p' /tmp/.bcrypt_err.$$)"
  fi
  rm -f /tmp/.bcrypt_err.$$ || true
  rm -f "$TMPDIR/temp_pass.txt" 2>/dev/null || true
  echo "$hashed"
}

_try_simple_hash() {
  local pass="$1"
  local hashed=""
  
  # Debug: Check if Python3 is available in container
  if ! docker exec "$SYNAPSE_CONTAINER" python3 --version >/dev/null 2>&1; then
    silent_log "Python3 not available in container for simple hash"
    return 1
  fi
  
  # Use a simpler approach without temp files first
  hashed=$(docker exec "$SYNAPSE_CONTAINER" python3 -c "
import hashlib, base64, sys
try:
    pw = '''$pass'''.encode('utf-8')
    hash_obj = hashlib.sha256(pw)
    print('sha256:' + base64.b64encode(hash_obj.digest()).decode('ascii'))
except Exception as e:
    sys.stderr.write('Hash error: ' + str(e))
    sys.exit(1)
" 2>/dev/null)
  
  if [[ -n "$hashed" && "$hashed" == sha256:* ]]; then
    echo "$hashed"
  else
    # Fallback: try with temp file method
    echo -n "$pass" > "$TMPDIR/temp_pass_simple.txt"
    docker cp "$TMPDIR/temp_pass_simple.txt" "$SYNAPSE_CONTAINER:/tmp/temp_pass_simple.txt"
    
    hashed=$(docker exec "$SYNAPSE_CONTAINER" python3 - <<'PY' 2>/dev/null
import hashlib, base64
try:
    with open('/tmp/temp_pass_simple.txt','r') as f:
        pw = f.read().encode('utf-8')
    hash_obj = hashlib.sha256(pw)
    print('sha256:' + base64.b64encode(hash_obj.digest()).decode('ascii'))
except Exception as e:
    import sys
    sys.stderr.write('File hash error: ' + str(e))
finally:
    try:
        import os
        os.remove('/tmp/temp_pass_simple.txt')
    except:
        pass
PY
)
    rm -f "$TMPDIR/temp_pass_simple.txt" 2>/dev/null || true
    echo "$hashed"
  fi
}

_try_basic_hash() {
  local pass="$1"
  # Ultra-simple hash using just shell commands (available everywhere)
  # MD5 - not secure but works as absolute fallback
  if command -v md5sum >/dev/null 2>&1; then
    echo "md5:$(echo -n "$pass" | md5sum | cut -d' ' -f1)"
  elif docker exec "$SYNAPSE_CONTAINER" sh -c "command -v md5sum >/dev/null 2>&1"; then
    docker exec "$SYNAPSE_CONTAINER" sh -c "echo -n '$pass' | md5sum | cut -d' ' -f1" | sed 's/^/md5:/'
  else
    # Even simpler - just base64 encode (not secure at all, but works)
    echo "plain64:$(echo -n "$pass" | base64)"
  fi
}

_attempt_install_bcrypt_in_container() {
  local mgr
  mgr=$(detect_package_manager_in_container "$SYNAPSE_CONTAINER")
  silent_log "Attempting to install bcrypt in container $SYNAPSE_CONTAINER using pkg manager: $mgr"

  # Try pre-built bcrypt packages first (faster and more reliable)
  if [[ "$mgr" == "apt" ]]; then
    if docker exec "$SYNAPSE_CONTAINER" sh -c "apt-get update >/dev/null 2>&1 && apt-get install -y python3-bcrypt >/dev/null 2>&1"; then
      silent_log "Installed python3-bcrypt package successfully"
    else
      # Fallback to pip install
      docker exec "$SYNAPSE_CONTAINER" sh -c "apt-get install -y python3-pip build-essential libssl-dev libffi-dev python3-dev >/dev/null 2>&1 && pip3 install bcrypt >/dev/null 2>&1" || return 1
    fi
  elif [[ "$mgr" == "apk" ]]; then
    if docker exec "$SYNAPSE_CONTAINER" sh -c "apk add --no-cache py3-bcrypt >/dev/null 2>&1"; then
      silent_log "Installed py3-bcrypt package successfully"
    else
      docker exec "$SYNAPSE_CONTAINER" sh -c "apk add --no-cache python3 py3-pip build-base libressl-dev libffi-dev python3-dev >/dev/null 2>&1 && pip3 install bcrypt >/dev/null 2>&1" || return 1
    fi
  elif [[ "$mgr" == "yum" ]]; then
    if docker exec "$SYNAPSE_CONTAINER" sh -c "yum install -y python3-bcrypt >/dev/null 2>&1"; then
      silent_log "Installed python3-bcrypt package successfully"
    else
      docker exec "$SYNAPSE_CONTAINER" sh -c "yum install -y python3-pip gcc openssl-devel libffi-devel python3-devel >/dev/null 2>&1 && pip3 install bcrypt >/dev/null 2>&1" || return 1
    fi
  else
    silent_log "No known package manager in container: $mgr"
    return 1
  fi

  # Verify bcrypt is actually importable
  if docker exec "$SYNAPSE_CONTAINER" python3 -c "import bcrypt" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# confirm with default = Yes
confirm_default_yes() {
  local prompt="${1:-Proceed?}"
  # prints: Prompt [Y/n]:
  read -r -p "$prompt [Y/n]: " ans
  ans="${ans:-Y}"
  if [[ "$ans" =~ ^[Yy] ]]; then return 0; else return 1; fi
}

# Try to install bcrypt on host (best-effort)
_attempt_install_bcrypt_on_host() {
  # Check network connectivity first
  if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "Network connectivity issue detected. Cannot reach package repositories."
    return 1
  fi
  
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y python3-bcrypt >/dev/null 2>&1 || \
    (sudo apt-get install -y build-essential libssl-dev libffi-dev python3-dev python3-pip >/dev/null 2>&1 && sudo pip3 install bcrypt >/dev/null 2>&1)
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache py3-bcrypt >/dev/null 2>&1 || \
    (sudo apk add --no-cache python3 py3-pip build-base libressl-dev libffi-dev >/dev/null 2>&1 && sudo pip3 install bcrypt >/dev/null 2>&1)
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y python3-bcrypt >/dev/null 2>&1 || \
    (sudo yum install -y python3-pip gcc openssl-devel libffi-devel >/dev/null 2>&1 && sudo pip3 install bcrypt >/dev/null 2>&1)
  else
    return 1
  fi
}

# Ensure bcrypt exists somewhere (container preferred). Prompts user (default Y) to install if missing.
ensure_bcrypt_available() {
  # 0 == OK (bcrypt available somewhere), 1 == not available
  local cont="$SYNAPSE_CONTAINER"
  # check in container
  if docker exec "$cont" sh -c 'python3 -c "import bcrypt" >/dev/null 2>&1' ; then
    return 0
  fi
  # check on host
  if python3 - <<'PY' 2>/dev/null
try:
    import bcrypt
    print("ok")
except Exception:
    raise SystemExit(1)
PY
  then
    return 0
  fi

  # not found: ask to install (default Y)
  echo ""
  echo "bcrypt python module not found in Synapse container or on host."
  echo "To create/reset passwords the script needs 'bcrypt'."
  if confirm_default_yes "Install bcrypt inside Synapse container?"; then
    echo "Attempting to install bcrypt inside container ($cont)..."
    if _attempt_install_bcrypt_in_container; then
      echo "Installed bcrypt inside container."
      # double-check
      if docker exec "$cont" sh -c 'python3 -c "import bcrypt" >/dev/null 2>&1' ; then
        return 0
      fi
    else
      echo "Auto-install inside container failed or not supported."
    fi
  fi

  # prompt to try host install if container install failed or user declined
  if confirm_default_yes "Try installing bcrypt on the host (requires sudo/root)?"; then
    echo "Attempting host install..."
    if _attempt_install_bcrypt_on_host; then
      echo "bcrypt installed on host."
      # double-check
      if python3 - <<'PY' 2>/dev/null
try:
    import bcrypt
    print("ok")
except Exception:
    raise SystemExit(1)
PY
      then
        return 0
      fi
    else
      echo "Host install failed or not supported."
    fi
  fi

  # final: not available
  return 1
}

create_user_interactive() {
  local localpart pass admin_flag result success=false full_username hashed_pass insert_query verify admin_val creation_ts method_used
  localpart=$(ui_input "Create User" "Enter username (without @ and domain):" "")
  if [[ -z "$localpart" ]]; then ui_msg "Cancelled" "No username provided"; return; fi
  pass=$(ui_password "Password" "Enter password for user '$localpart':")
  if [[ -z "$pass" ]]; then ui_msg "Cancelled" "No password provided"; return; fi
  if confirm "Make this user an admin?"; then admin_flag="--admin"; else admin_flag="--no-admin"; fi
  if ! confirm "Create user '$localpart' with admin=${admin_flag:-no}?"; then ui_msg "Cancelled" "User creation cancelled"; return; fi

  full_username="@${localpart}:${DOMAIN}"

  silent_log "Creating user ${localpart} (admin=${admin_flag})"

  # Try register_new_matrix_user variants first (preferred)
  local register_cmds=(
    "register_new_matrix_user -u '${localpart}' -p '${pass}' ${admin_flag} -c '${HOMESERVER_YAML_PATH}' http://localhost:8008"
    "python3 -m synapse.app.register_new_matrix_user -u '${localpart}' -p '${pass}' ${admin_flag} -c '${HOMESERVER_YAML_PATH}' http://localhost:8008"
    "/usr/local/bin/register_new_matrix_user -u '${localpart}' -p '${pass}' ${admin_flag} -c '${HOMESERVER_YAML_PATH}' http://localhost:8008"
    "python3 -m synapse.app.register_new_matrix_user -u '${localpart}' -p '${pass}' ${admin_flag} -c '${HOMESERVER_YAML_PATH}' http://127.0.0.1:8008"
  )

  # Try register_new_matrix_user variants
  for cmd in "${register_cmds[@]}"; do
    silent_log "Trying register command in container: $cmd"
    result="$(docker exec "$SYNAPSE_CONTAINER" sh -c "$cmd" 2>&1)"
    rc=$?
    silent_log "register_new_matrix_user rc=${rc} output-preview: $(printf '%.400s' "$result" | tr '\n' ' ' )"
    
    if [[ $rc -eq 0 ]]; then
      if ! echo "$result" | grep -qi -e "error" -e "no module named" -e "bcrypt not" -e "cannot create password hash"; then
        success=true
        method_used="register_new_matrix_user"
        break
      else
        silent_log "Register tool returned rc=0 but output indicates failure: $result"
      fi
    else
      silent_log "Register tool failed (rc=$rc). Output: $result"
    fi
  done

  # If register tool failed, try direct DB INSERT with multiple hashing methods
  if ! $success; then
    admin_val=0; [[ "$admin_flag" == "--admin" ]] && admin_val=1
    creation_ts=$(($(date +%s)))  # seconds
    
    # Try multiple hashing methods in order of preference
    method_used=""
    
    # Method 1: Try Synapse native hash_password
    hashed_pass="$(_try_hash_synapse_native "$pass")"
    if [[ -n "$hashed_pass" ]]; then
      method_used="Synapse native hash_password"
    else
      # Method 2: Try bcrypt in container
      hashed_pass="$(_try_hash_in_container "$pass")"
      if [[ -n "$hashed_pass" ]]; then
        method_used="bcrypt (container)"
      else
        # Method 3: Try bcrypt on host
        hashed_pass="$(_try_hash_on_host "$pass")"
        if [[ -n "$hashed_pass" ]]; then
          method_used="bcrypt (host)"
        else
          # Method 4: Try simple hash
          hashed_pass="$(_try_simple_hash "$pass")"
          if [[ -n "$hashed_pass" ]]; then
            method_used="SHA256 (simple)"
            echo "WARNING: Using simple hash - less secure than bcrypt"
          else
            # Method 5: Offer manual hash input or installation
            echo ""
            echo "Automatic password hashing failed."
            echo ""
            echo "Options:"
            echo "1. Provide manual bcrypt hash (most secure)"
            echo "2. Try to install bcrypt in container"
            echo "3. Cancel user creation"
            echo ""
            read -r -p "Choose option [1-3]: " choice
            
            case "$choice" in
              "1")
                echo ""
                echo "Generate bcrypt hash manually:"
                echo "On a system with Python + bcrypt, run:"
                echo "python3 -c \"import bcrypt; print(bcrypt.hashpw(b'$pass', bcrypt.gensalt()).decode())\""
                echo ""
                manual_hash=$(ui_input "Manual Hash" "Paste the bcrypt hash here:" "")
                if [[ -n "$manual_hash" && "$manual_hash" =~ ^\$2[ab]\$ ]]; then
                  hashed_pass="$manual_hash"
                  method_used="manual bcrypt"
                else
                  ui_msg "Invalid Hash" "Invalid bcrypt hash format. User creation cancelled."
                  return
                fi
                ;;
              "2")
                if confirm "Try to install python3-bcrypt in the Synapse container?"; then
                  if _attempt_install_bcrypt_in_container; then
                    hashed_pass="$(_try_hash_in_container "$pass")"
                    if [[ -n "$hashed_pass" ]]; then
                      method_used="bcrypt (container - newly installed)"
                    else
                      result="bcrypt installation succeeded but hashing still failed."
                    fi
                  else
                    result="Auto-install of bcrypt in container failed or unsupported."
                  fi
                else
                  result="bcrypt installation declined by user."
                fi
                ;;
              *)
                ui_msg "Cancelled" "User creation cancelled."
                return
                ;;
            esac
          fi
        fi
      fi
    fi

    if [[ -n "$hashed_pass" ]]; then
      if [[ "$DB_TYPE" == "postgres" ]]; then
        insert_query="INSERT INTO users (name, password_hash, creation_ts, admin, deactivated, is_guest, user_type, approved) VALUES ('${full_username}', '${hashed_pass}', ${creation_ts}, ${admin_val}, 0, 0, NULL, TRUE) ON CONFLICT (name) DO NOTHING;"
      else
        insert_query="INSERT OR IGNORE INTO users (name, password_hash, creation_ts, admin, deactivated, is_guest, user_type, approved) VALUES ('${full_username}', '${hashed_pass}', ${creation_ts}, ${admin_val}, 0, 0, NULL, 1);"
      fi
      result=$(safe_write_query "$insert_query" || echo "Error inserting user")
      
      # verify
      verify=$(execute_query "SELECT name FROM users WHERE name='${full_username}' LIMIT 1;" 2>/dev/null || true)
      if [[ -n "$verify" ]] && [[ "$verify" == *"${full_username}"* ]]; then
        success=true
        result="User created directly in database using $method_used: ${full_username}"
      else
        success=false
        result="Insert did not persist (no matching row found). SQL result: ${result}"
      fi
    else
      result="Could not generate password hash using any available method."
    fi
  fi

  if $success; then
    display=$(printf "Successfully created user: %s\nMethod: %s\n\nOutput:\n%s\n" "$full_username" "${method_used:-register_new_matrix_user}" "$result")
    show_results "User Created" "$display"
    silent_log "User created successfully: $full_username using ${method_used:-register_new_matrix_user}"
  else
    display=$(printf "Failed to create user: %s\n\nError:\n%s\n\nTip: Consider using a system with bcrypt available, or manually generate bcrypt hashes externally." "@${localpart}:${DOMAIN}" "$result")
    show_results "Creation Failed" "$display"
    silent_log "Failed to create user: $result"
  fi
}

reset_password_interactive() {
  local input username pass hashed_pass result update_query display verify_val method_used
  input=$(ui_input "Reset Password" "Enter username:" "")
  if [[ -z "$input" ]]; then ui_msg "Cancelled" "No username provided"; return; fi
  username=$(normalize_username "$input")
  pass=$(ui_password "New Password" "Enter new password for '$username':")
  if [[ -z "$pass" ]]; then ui_msg "Cancelled" "No password provided"; return; fi
  if ! confirm "Reset password for user '$username'?"; then ui_msg "Cancelled" "Password reset cancelled"; return; fi
  
  # Try multiple hashing methods in order of preference
  method_used=""
  
  # Method 1: Try Synapse native hash_password
  hashed_pass="$(_try_hash_synapse_native "$pass")"
  if [[ -n "$hashed_pass" ]]; then
    method_used="Synapse native hash_password"
  else
    # Method 2: Try bcrypt in container
    hashed_pass="$(_try_hash_in_container "$pass")"
    if [[ -n "$hashed_pass" ]]; then
      method_used="bcrypt (container)"
    else
      # Method 3: Try bcrypt on host
      hashed_pass="$(_try_hash_on_host "$pass")"
      if [[ -n "$hashed_pass" ]]; then
        method_used="bcrypt (host)"
      else
        # Method 4: Offer manual hash input
        echo ""
        echo "Automatic password hashing failed."
        echo ""
        echo "Options:"
        echo "1. Manual bcrypt hash (most secure)"
        echo "2. Use simple hash (less secure but works)"
        echo "3. Cancel"
        echo ""
        read -r -p "Choose option [1-3]: " choice
        
        case "$choice" in
          "1")
            echo ""
            echo "Generate bcrypt hash manually:"
            echo "On a system with Python + bcrypt, run:"
            echo "python3 -c \"import bcrypt; print(bcrypt.hashpw(b'$pass', bcrypt.gensalt()).decode())\""
            echo ""
            manual_hash=$(ui_input "Manual Hash" "Paste the bcrypt hash here:" "")
            if [[ -n "$manual_hash" && "$manual_hash" =~ ^\$2[ab]\$ ]]; then
              hashed_pass="$manual_hash"
              method_used="manual bcrypt"
            else
              ui_msg "Invalid Hash" "Invalid bcrypt hash format."
              return
            fi
            ;;
          "2")
            hashed_pass="$(_try_basic_hash "$pass")"
            if [[ -n "$hashed_pass" ]]; then
              method_used="Basic hash (INSECURE - change ASAP!)"
              echo "WARNING: Using basic hash - VERY insecure. Change this password ASAP after installing bcrypt!"
            else
              ui_msg "Error" "All hash generation methods failed."
              return
            fi
            ;;
          *)
            ui_msg "Cancelled" "Password reset cancelled."
            return
            ;;
        esac
      fi
    fi
  fi
  
  if [[ -n "$hashed_pass" ]]; then
    update_query="UPDATE users SET password_hash='${hashed_pass}' WHERE name='${username}';"
    result=$(safe_write_query "$update_query" || echo "Error updating password")
    verify_val=$(execute_query "SELECT name FROM users WHERE name='${username}' LIMIT 1;" 2>/dev/null || echo "")
    if [[ -n "$verify_val" ]] && [[ "$verify_val" == *"${username}"* ]]; then
      display=$(printf "Password reset for: %s\nMethod used: %s\n\nResult:\n%s\n" "$username" "$method_used" "$result")
      show_results "Password Reset" "$display"
      silent_log "Password reset for: $username using $method_used"
    else
      display=$(printf "Password reset failed for %s\nUser may not exist in database.\n\nDB output:\n%s" "$username" "$verify_val")
      show_results "Password Reset Failed" "$display"
    fi
  else
    ui_msg "Error" "Could not generate password hash using any available method."
  fi
}

deactivate_user_interactive() {
  local input username result display verify_val user_exists
  input=$(ui_input "Deactivate User" "Enter username to deactivate:" "")
  if [[ -z "$input" ]]; then ui_msg "Cancelled" "No username provided"; return; fi
  username=$(normalize_username "$input")
  
  # Check if user exists first
  user_exists=$(execute_query "SELECT name FROM users WHERE name='${username}' LIMIT 1;" 2>/dev/null || echo "")
  if [[ -z "$user_exists" ]] || [[ "$user_exists" == "name" ]] || [[ $(echo "$user_exists" | grep -v "name" | wc -l) -eq 0 ]]; then
    ui_msg "Error" "User '$username' not found in database. Please check the username and try again."
    return
  fi
  
  if ! confirm "Deactivate (soft delete) user '$username'? This will disable the account."; then ui_msg "Cancelled" "Deactivation cancelled"; return; fi
  result=$(safe_write_query "UPDATE users SET deactivated=1 WHERE name='${username}';" || echo "Error deactivating user")
  
  # verify
  verify_val=$(execute_query "SELECT name, deactivated FROM users WHERE name='${username}' LIMIT 1;" 2>/dev/null || echo "")
  if [[ ! "$result" =~ "Error" ]] && [[ -n "$verify_val" ]] && echo "$verify_val" | grep -q '1'; then
    display=$(printf "Deactivated user: %s\n\nResult:\n%s\n" "$username" "$result")
  else
    display=$(printf "Deactivation failed for %s. DB output:\n%s\n\nRaw result:\n%s\n\nTip: If using SQLite, WAL mode may cause persistent locks—try manual stop/restart or migrate to Postgres (recommended for Synapse). Check logs for details." "$username" "$verify_val" "$result")
  fi
  show_results "User Deactivation Result" "$display"
  silent_log "Deactivated user: $username"
}


reactivate_user_interactive() {
  local input username result display verify_val
  input=$(ui_input "Reactivate User" "Enter username to reactivate:" "")
  if [[ -z "$input" ]]; then ui_msg "Cancelled" "No username provided"; return; fi
  username=$(normalize_username "$input")
  if ! confirm "Reactivate user '$username'?"; then ui_msg "Cancelled" "Reactivation cancelled"; return; fi
  result=$(safe_write_query "UPDATE users SET deactivated=0 WHERE name='${username}';" || echo "Error reactivating user")  # verify
  verify_val=$(execute_query "SELECT name, deactivated FROM users WHERE name='${username}' LIMIT 1;" 2>/dev/null || echo "")
  if [[ ! "$result" =~ "Error" ]] && [[ -n "$verify_val" ]] && echo "$verify_val" | grep -q '0'; then
    display=$(printf "Reactivated user: %s\n\nResult:\n%s\n" "$username" "$result")
  else
    display=$(printf "Reactivation failed for %s. DB output:\n%s\n\nRaw result:\n%s\n\nTip: If using SQLite, WAL mode may cause persistent locks—try manual stop/restart or migrate to Postgres (recommended for Synapse). Check logs for details." "$username" "$verify_val" "$result")
  fi
  show_results "User Reactivation Result" "$display"
  silent_log "Reactivated user: $username"
}


backup_database() {
  silent_log "Starting database backup..."
  local timestamp backup_file
  timestamp=$(date '+%Y%m%d_%H%M%S')
  if [[ "$DB_TYPE" == "postgres" ]]; then
    backup_file="${SCRIPT_DIR}/synapse_postgres_backup_${timestamp}.sql"
    if docker exec "$POSTGRES_CONTAINER" env PGPASSWORD="$PG_PASS" pg_dump -U "$PG_USER" "$PG_DB" > "$backup_file" 2>/dev/null; then
      local size; size=$(du -h "$backup_file" | cut -f1)
      show_results "Backup Complete" "PostgreSQL backup saved to:\n$backup_file\n\nSize: $size"
      silent_log "Backup saved to: $backup_file"
    else
      show_results "Backup Failed" "Failed to create PostgreSQL backup"
      silent_log "Backup failed"
    fi
  else
    backup_file="${SCRIPT_DIR}/synapse_sqlite_backup_${timestamp}.db"
    # Use python backup inside container to avoid WAL issues, stream to host file
    docker exec -i -e SQLITE_DB_PATH="$SQLITE_PATH" "$SYNAPSE_CONTAINER" python3 - <<'PY' >"$backup_file"
import sqlite3,sys,os,tempfile
src=os.environ.get('SQLITE_DB_PATH','/data/homeserver.db')
tmp=tempfile.mktemp()
bck=sqlite3.connect(tmp)
src_conn=sqlite3.connect(src)
with bck:
    src_conn.backup(bck)
bck.close()
src_conn.close()
with open(tmp,'rb') as f:
    sys.stdout.buffer.write(f.read())
os.remove(tmp)
PY
    if [[ -f "$backup_file" ]]; then
      local size; size=$(du -h "$backup_file" | cut -f1)
      show_results "Backup Complete" "SQLite backup saved to:\n$backup_file\n\nSize: $size"
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
  if [[ -z "$sql" ]]; then ui_msg "Cancelled" "No query provided"; return; fi
  if ! confirm "Execute this SQL query?\n\n$sql"; then ui_msg "Cancelled" "Query execution cancelled"; return; fi
  result=$(execute_query "$sql" 2>&1 || echo "Query execution failed")
  show_results "Query Results" "$result"
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
      "8" "Run custom SQL query")
    if [[ -z "$choice" ]]; then continue; fi
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
      *) echo -e "${RED}Invalid choice: $choice${NC}" >&2; continue ;;
    esac
  done
}

# ---------- ENTRY ----------
main() {
  echo "Starting Matrix User Manager..."
  check_requirements
  setup_ui
  echo -e "${CYAN}Detecting Matrix containers...${NC}"
  detect_containers
  echo -e "${CYAN}Reading Matrix configuration...${NC}"
  read_homeserver_yaml
  echo -e "${CYAN}Configuring database access...${NC}"
  detect_database_config

  local welcome_msg="Matrix User Manager - Configuration Complete

✓ Synapse container: $SYNAPSE_CONTAINER
✓ Database type: $DB_TYPE"
  if [[ "$DB_TYPE" == "postgres" ]]; then
    welcome_msg+="
✓ PostgreSQL container: $POSTGRES_CONTAINER  
✓ Database: $PG_USER@$PG_HOST:$PG_PORT/$PG_DB"
  else
    welcome_msg+="
✓ SQLite database: $SQLITE_PATH"
  fi
  welcome_msg+="
✓ Matrix domain: $DOMAIN
✓ Config file: $HOMESERVER_YAML_PATH
✓ Log file: $LOGFILE

Ready to manage Matrix users!"

  show_results "Setup Complete" "$welcome_msg"

  log "=== Matrix User Manager Started ==="
  log "Synapse: $SYNAPSE_CONTAINER, DB: $DB_TYPE, Domain: $DOMAIN"

  main_menu

  echo -e "${GREEN}Matrix User Manager exited. Goodbye!${NC}"
  log "=== Matrix User Manager Ended ==="
}

main "$@"
