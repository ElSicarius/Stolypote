#!/usr/bin/env bash
#
# start.sh
# Dynamically sets up:
#   - docker-compose.yml (which ports to map for caddy)
#   - caddy/Caddyfile (which ports to listen on).
#
# Port 443 => Let's Encrypt if domain is provided, else internal TLS if no domain.
# Other "common TLS" ports => always internal TLS.
# All remaining ports => plain HTTP.
#
# EXAMPLES:
#   # Single domain, 443 => Let's Encrypt, 8443 => internal, 80 => plain
#   ./start.sh -p "80,443,8443" -d "example.com"
#
#   # Multiple domains, 443 => LE, 8080 => plain, no domain => internal only if it's 443 or 8443
#   ./start.sh -p "443,8080,8443" -d domain1.com -d domain2.org
#
#   # If no domain => 443 => internal TLS, 8443 => internal TLS, etc.
#   ./start.sh -p "80,443,8443"
#

set -e

PORT_SPEC=""
PORT_FILE=""
declare -a DOMAINS=()

# We define two sets of "TLS" ports:
#  1) TRUSTED_PORTS -> [443]
#  2) COMMON_TLS_PORTS -> [8443, 9443, 10443] (example)
TRUSTED_PORTS=(443)
COMMON_TLS_PORTS=(8443 9443 10443)

function usage() {
  echo "Usage: $0 [ -p \"port-spec\" | -f <port-file> ] [ -d <domain> (repeatable) ]"
  echo "  -p \"...\"   => comma list or a range (e.g. '80,443' or '3000-3010')"
  echo "  -f <file>   => file with one port per line"
  echo "  -d <domain> => e.g. 'example.com' (can be repeated)"
  exit 1
}

# Helpers to see if a port is 443 or in our other TLS list
function is_trusted_port() {
  local p="$1"
  for tport in "${TRUSTED_PORTS[@]}"; do
    if [[ "$p" == "$tport" ]]; then
      return 0
    fi
  done
  return 1
}

function is_common_tls_port() {
  local p="$1"
  for tlsport in "${COMMON_TLS_PORTS[@]}"; do
    if [[ "$p" == "$tlsport" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  key="$1"
  case "$key" in
    -p|--ports)
      PORT_SPEC="$2"
      shift; shift
      ;;
    -f|--file)
      PORT_FILE="$2"
      shift; shift
      ;;
    -d|--domain)
      DOMAINS+=( "$2" )
      shift; shift
      ;;
    *)
      echo "[!] Unknown argument: $1"
      usage
      ;;
  esac
done

# Basic validation: must supply either -p or -f
if [[ -z "$PORT_SPEC" && -z "$PORT_FILE" ]]; then
  echo "[!] You must provide ports with -p or -f"
  usage
fi

if [[ -n "$PORT_SPEC" && -n "$PORT_FILE" ]]; then
  echo "[!] Please specify EITHER -p or -f, not both."
  usage
fi

if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  echo "[+] Domains: ${DOMAINS[*]}"
else
  echo "[+] No domains specified -> 443 (if used) and other TLS ports => internal certificates."
fi

# --- Collect ports into an array ---
declare -a PORT_ARRAY=()

# Helper function to add a single port (validates range 1..65535)
function add_port() {
  local p="$1"
  if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p>0 && p<=65535 )); then
    PORT_ARRAY+=("$p")
  else
    echo "[!] Skipping invalid port: $p"
  fi
}

# If user gave a file
if [[ -n "$PORT_FILE" ]]; then
  echo "[+] Reading ports from file: $PORT_FILE"
  if [[ ! -f "$PORT_FILE" ]]; then
    echo "[!] File not found: $PORT_FILE"
    exit 1
  fi
  while read -r line; do
    line="$(echo "$line" | xargs)"  # trim
    [[ -z "$line" ]] && continue
    add_port "$line"
  done < "$PORT_FILE"
fi

# If user gave a port spec (could be comma-list or range)
if [[ -n "$PORT_SPEC" ]]; then
  echo "[+] Parsing port spec: $PORT_SPEC"

  # If it's a range "start-end"
  if [[ "$PORT_SPEC" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    START="${BASH_REMATCH[1]}"
    END="${BASH_REMATCH[2]}"
    if (( START > END )); then
      echo "[!] Invalid range: $PORT_SPEC"
      exit 1
    fi
    for ((p=START; p<=END; p++)); do
      add_port "$p"
    done
  else
    # else assume comma-separated or single
    IFS=',' read -ra SPLIT <<< "$PORT_SPEC"
    for p in "${SPLIT[@]}"; do
      p="$(echo "$p" | xargs)"
      [[ -n "$p" ]] && add_port "$p"
    done
  fi
fi

# Remove duplicates
declare -A SEEN
UNIQUE_PORTS=()
for p in "${PORT_ARRAY[@]}"; do
  if [[ -z "${SEEN[$p]}" ]]; then
    SEEN[$p]=1
    UNIQUE_PORTS+=("$p")
  fi
done

if [[ ${#UNIQUE_PORTS[@]} -eq 0 ]]; then
  echo "[!] No valid ports found."
  exit 1
fi

echo "[+] Final port list: ${UNIQUE_PORTS[*]}"

# --- Step 1: Generate docker-compose.yml ---
cat > docker-compose.yml <<EOF
version: '3.8'

services:
  stolypote:
    build:
      context: ./stolypote
    container_name: stolypote
    restart: unless-stopped
    networks:
      - hpnet
    volumes:
      - ./wordlists:/app/wordlists  # honeypot data

  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    networks:
      - hpnet
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
    ports:
EOF

# For each port, map HOST:PORT -> caddy:PORT
for p in "${UNIQUE_PORTS[@]}"; do
  echo "      - \"$p:$p\"" >> docker-compose.yml
done

cat >> docker-compose.yml <<EOF

networks:
  hpnet:
    driver: bridge
EOF

echo "[+] Created docker-compose.yml with mapped ports."

# --- Step 2: Generate caddy/Caddyfile ---
mkdir -p caddy

cat > caddy/Caddyfile <<EOF
{
    servers {
        protocols h1 h2 h2c
    }
}
EOF

#############################################################
# If domains are given -> For each domain, for each port:
#  - if p in TRUSTED_PORTS (443): Let's Encrypt
#  - if p in COMMON_TLS_PORTS (8443 etc.): internal TLS
#  - else plain HTTP
#############################################################
if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  for domain in "${DOMAINS[@]}"; do
    for p in "${UNIQUE_PORTS[@]}"; do
      if is_trusted_port "$p"; then
        # => Let's Encrypt
cat >> caddy/Caddyfile <<EOF

${domain}:${p} {
    tls admin@${domain}
    reverse_proxy stolypote:65111
}
EOF

      elif is_common_tls_port "$p"; then
        # => internal TLS
cat >> caddy/Caddyfile <<EOF

${domain}:${p} {
    tls internal
    reverse_proxy stolypote:65111
}
EOF

      else
        # => plain HTTP
cat >> caddy/Caddyfile <<EOF

${domain}:${p} {
    reverse_proxy stolypote:65111
}
EOF
      fi
    done
  done

#############################################################
# If NO domains -> fallback for each port:
#  - if p in TRUSTED_PORTS or COMMON_TLS_PORTS => internal TLS
#  - else plain HTTP
#############################################################
else
  for p in "${UNIQUE_PORTS[@]}"; do
    if is_trusted_port "$p" || is_common_tls_port "$p"; then
      cat >> caddy/Caddyfile <<EOF

:${p} {
    tls internal
    reverse_proxy stolypote:65111
}
EOF
    else
      cat >> caddy/Caddyfile <<EOF

:${p} {
    reverse_proxy stolypote:65111
}
EOF
    fi
  done
fi

echo "[+] Created caddy/Caddyfile."

# --- Step 3: Build & run ---
echo "[+] Building Docker images..."
docker compose build --no-cache

echo "[+] Starting containers..."
docker compose up -d

echo "[+] Done. Use 'docker compose logs -f' to follow logs."
