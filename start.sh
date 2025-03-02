#!/usr/bin/env bash
#
# start.sh
# Dynamically sets up:
#   - docker-compose.yml (which ports to map for caddy)
#   - caddy/Caddyfile (which ports to listen on).
#
#   Only ports in COMMON_TLS_PORTS[] get TLS (LE or internal).
#   All other ports are plain HTTP, even if a domain is specified.
#
# USAGE EXAMPLES:
#   # Single domain, sets TLS on ports 443,8443, but not on 80:
#   ./start.sh -p "80,443,8443" -d "example.com"
#
#   # Multiple domains, sets TLS only on common ports, e.g., 443:
#   ./start.sh -p "443,8080,9999" -d domain1.com -d domain2.org
#
#   # No domains => internal TLS only on 443,8443, etc. Plain HTTP on everything else.
#   ./start.sh -p "80,443" 
#

set -e

PORT_SPEC=""
PORT_FILE=""
# We store all domains in an array
declare -a DOMAINS=()

# Define which ports should use TLS
COMMON_TLS_PORTS=(443 8443 9443 10443)

function usage() {
  echo "Usage: $0 [ -p \"port-spec\" | -f <port-file> ] [ -d <domain> (repeatable) ]"
  echo "  -p \"...\"   => comma list or a range (e.g. '80,443' or '3000-3010')"
  echo "  -f <file>   => file with one port per line (e.g. 'ports/top10.txt')"
  echo "  -d <domain> => e.g. 'example.com' (can be repeated)"
  exit 1
}

# Check if a port is in COMMON_TLS_PORTS
function is_common_https_port() {
  local port="$1"
  for tlsport in "${COMMON_TLS_PORTS[@]}"; do
    if [[ "$port" == "$tlsport" ]]; then
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
  echo "[+] No domains specified. We'll do plain HTTP or internal TLS for known TLS ports."
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
    # stolypote listens on 65111 inside container
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

# For each port, we map HOST:PORT -> caddy:PORT
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

# We'll define site blocks for each domain + each port differently
# based on whether the port is in the "common TLS" set.

#############################################################
# 2a) If domains are given
#############################################################
if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  for domain in "${DOMAINS[@]}"; do
    for p in "${UNIQUE_PORTS[@]}"; do
      if is_common_https_port "$p"; then
        # Domain + known HTTPS port => let's encrypt
        cat >> caddy/Caddyfile <<EOF

${domain}:${p} {
    tls admin@${domain}
    reverse_proxy stolypote:65111
}
EOF
      else
        # Domain + non-HTTPS port => plain HTTP
        cat >> caddy/Caddyfile <<EOF

${domain}:${p} {
    reverse_proxy stolypote:65111
}
EOF
      fi
    done
  done

#############################################################
# 2b) No domains => fallback for each port
#############################################################
else
  # No domains specified
  for p in "${UNIQUE_PORTS[@]}"; do
    if is_common_https_port "$p"; then
      # known TLS port => internal TLS
      cat >> caddy/Caddyfile <<EOF

:${p} {
    tls internal
    reverse_proxy stolypote:65111
}
EOF
    else
      # plain HTTP
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
docker compose build

echo "[+] Starting containers..."
docker compose up -d

echo "[+] Done. Use 'docker compose logs -f' to follow logs."
