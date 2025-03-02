#!/usr/bin/env bash
#
# start.sh - Updated to handle unified TLS blocks properly
#

set -e

PORT_SPEC=""
PORT_FILE=""
declare -a DOMAINS=()

# Define which ports are "TLS" ports
ALL_TLS_PORTS=(443 8443 9443 10443)

function usage() {
  echo "Usage: $0 [ -p \"port-spec\" | -f <port-file> ] [ -d <domain> (repeatable) ]"
  echo "  -p \"...\"   => comma list or a range (e.g. '80,443' or '3000-3010')"
  echo "  -f <file>   => file with one port per line"
  echo "  -d <domain> => e.g. 'example.com' (can be repeated)"
  exit 1
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

# Must provide either -p or -f
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
  echo "[+] No domains specified -> using 'tls internal' for TLS ports."
fi

# --- Collect ports into an array ---
declare -a PORT_ARRAY=()

# Helper function to add a single port if valid
function add_port() {
  local p="$1"
  if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p>0 && p<=65535 )); then
    PORT_ARRAY+=( "$p" )
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

# If user gave a port spec
if [[ -n "$PORT_SPEC" ]]; then
  echo "[+] Parsing port spec: $PORT_SPEC"
  if [[ "$PORT_SPEC" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    # range
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
    # comma-separated
    IFS=',' read -ra SPLIT <<< "$PORT_SPEC"
    for p in "${SPLIT[@]}"; do
      p="$(echo "$p" | xargs)"
      [[ -n "$p" ]] && add_port "$p"
    done
  fi
fi

# Deduplicate
declare -A SEEN
UNIQUE_PORTS=()
for p in "${PORT_ARRAY[@]}"; do
  if [[ -z "${SEEN[$p]}" ]]; then
    SEEN[$p]=1
    UNIQUE_PORTS+=( "$p" )
  fi
done

if [[ ${#UNIQUE_PORTS[@]} -eq 0 ]]; then
  echo "[!] No valid ports found."
  exit 1
fi

echo "[+] Final port list: ${UNIQUE_PORTS[*]}"

# Split into TLS_PORTS vs HTTP_PORTS
declare -a TLS_PORTS=()
declare -a HTTP_PORTS=()

# If a port is in ALL_TLS_PORTS, treat it as TLS, otherwise plain HTTP
for p in "${UNIQUE_PORTS[@]}"; do
  if [[ " ${ALL_TLS_PORTS[*]} " =~ " ${p} " ]]; then
    TLS_PORTS+=( "$p" )
  else
    HTTP_PORTS+=( "$p" )
  fi
done

echo "[+] TLS ports: ${TLS_PORTS[*]}"
echo "[+] HTTP ports: ${HTTP_PORTS[*]}"

# --- Generate docker-compose.yml ---
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
      - ./wordlists:/app/wordlists

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

for p in "${UNIQUE_PORTS[@]}"; do
  echo "      - \"$p:$p\"" >> docker-compose.yml
done

cat >> docker-compose.yml <<EOF

networks:
  hpnet:
    driver: bridge
EOF

echo "[+] Created docker-compose.yml."

# --- Generate caddy/Caddyfile ---
mkdir -p caddy
cat > caddy/Caddyfile <<EOF
{
    servers {
        protocols h1 h2 h2c
    }
}
EOF

if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  for domain in "${DOMAINS[@]}"; do
    if [[ ${#TLS_PORTS[@]} -gt 0 ]]; then
      TLS_ADDRESSES=$(printf " %s:%s" "$domain" "${TLS_PORTS[@]}")
      cat >> caddy/Caddyfile <<EOF

$TLS_ADDRESSES {
    tls admin@${domain}
    reverse_proxy stolypote:65111
}
EOF
    fi

    for p in "${HTTP_PORTS[@]}"; do
      cat >> caddy/Caddyfile <<EOF

${domain}:${p} {
    reverse_proxy stolypote:65111
}
EOF
    done
  done
else
  if [[ ${#TLS_PORTS[@]} -gt 0 ]]; then
    TLS_ADDRESSES=$(printf " :%s" "${TLS_PORTS[@]}")
    cat >> caddy/Caddyfile <<EOF

$TLS_ADDRESSES {
    tls internal
    reverse_proxy stolypote:65111
}
EOF
  fi

  for p in "${HTTP_PORTS[@]}"; do
    cat >> caddy/Caddyfile <<EOF

:${p} {
    reverse_proxy stolypote:65111
}
EOF
  done
fi

echo "[+] Created caddy/Caddyfile."

# --- Start Docker services ---
echo "[+] Building Docker images..."
docker compose build --no-cache

echo "[+] Starting containers..."
docker compose up -d

echo "[+] Done. Use 'docker compose logs -f' to watch logs."
