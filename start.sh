#!/usr/bin/env bash
#
# start.sh
# Dynamically sets up:
#   - docker-compose.yml (which ports to map for caddy)
#   - caddy/Caddyfile (which ports to listen on).
#
# Behavior:
#   - If one or more domains are specified:
#       * For each domain, unify all "TLS" ports (443,8443,9443,10443, etc.) into ONE block with Let’s Encrypt
#         (443) or the same cert across them all. 
#       * Everything else is plain HTTP for domain:port.
#   - If NO domain is given:
#       * All "TLS" ports are grouped into ONE block with `tls internal`.
#       * Everything else is plain HTTP.
#
# This way:
#   * We don't define the same domain on multiple ports with different TLS settings,
#     avoiding "hostname appears in more than one automation policy".
#   * We can keep 443 and 8443, etc. in the same site block, reusing the same certificate.
#
# Examples:
#   # Single domain, user ports 80,443,8443 => unify 443 & 8443 in one block => domain:443,8443
#   # and 80 => plain
#   ./start.sh -p "80,443,8443" -d "example.com"
#
#   # Multiple domains, all TLS ports are grouped for each domain
#   ./start.sh -p "443,8080,8443,9443" -d domain1.com -d domain2.net
#     => domain1.com:443,8443,9443 { ... } + domain1.com:8080 { plain }
#        domain2.net:443,8443,9443 { ... } + domain2.net:8080 { plain }
#
#   # No domain => all TLS ports => single block with `tls internal`, everything else => plain
#   ./start.sh -p "80,443,8443"
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

# Must supply either -p or -f
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
  echo "[+] No domains specified -> TLS ports => internal cert, rest => plain HTTP."
fi

# --- Collect ports into an array ---
declare -a PORT_ARRAY=()

# Helper: add single port if valid
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
    line="$(echo "$line" | xargs)" # trim
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
    UNIQUE_PORTS+=("$p")
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

for p in "${UNIQUE_PORTS[@]}"; do
  # If p is in ALL_TLS_PORTS
  for t in "${ALL_TLS_PORTS[@]}"; do
    if [[ "$p" == "$t" ]]; then
      TLS_PORTS+=( "$p" )
      continue 2
    fi
  done
  # else it's an HTTP port
  HTTP_PORTS+=( "$p" )
done

echo "[+] TLS ports: ${TLS_PORTS[*]}"
echo "[+] Plain HTTP ports: ${HTTP_PORTS[*]}"

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

# Map each user port on host to container
for p in "${UNIQUE_PORTS[@]}"; do
  echo "      - \"$p:$p\"" >> docker-compose.yml
done

cat >> docker-compose.yml <<EOF

networks:
  hpnet:
    driver: bridge
EOF

echo "[+] Created docker-compose.yml."

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
# If domains -> each domain gets:
#   domain:TLS_PORTS (all in one line) => LE cert
#   domain:HTTP_PORT => plain
# If no domains -> all TLS_PORTS in one single block => internal
#                + each HTTP_PORT => plain
#############################################################

if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  # We have domains
  # Build a comma-separated list of TLS ports
  if [[ ${#TLS_PORTS[@]} -gt 0 ]]; then
    TLS_JOINED="$(IFS=','; echo "${TLS_PORTS[*]}")"  # e.g. "443,8443,9443"
  fi

  for domain in "${DOMAINS[@]}"; do
    # 1) If we have TLS_PORTS => unify them
    if [[ -n "$TLS_JOINED" ]]; then
      cat >> caddy/Caddyfile <<EOF

${domain}:${TLS_JOINED} {
    tls admin@${domain}
    reverse_proxy stolypote:65111
}
EOF
    fi

    # 2) For each plain HTTP port
    for p in "${HTTP_PORTS[@]}"; do
cat >> caddy/Caddyfile <<EOF

${domain}:${p} {
    reverse_proxy stolypote:65111
}
EOF
    done
  done

else
  # No domains => unify all TLS ports as :443,8443,9443 => internal
  if [[ ${#TLS_PORTS[@]} -gt 0 ]]; then
    TLS_JOINED="$(IFS=','; echo "${TLS_PORTS[*]}")"
    cat >> caddy/Caddyfile <<EOF

:${TLS_JOINED} {
    tls internal
    reverse_proxy stolypote:65111
}
EOF
  fi

  # For each plain HTTP port
  for p in "${HTTP_PORTS[@]}"; do
cat >> caddy/Caddyfile <<EOF

:${p} {
    reverse_proxy stolypote:65111
}
EOF
  done
fi

echo "[+] Created caddy/Caddyfile."

# --- Step 3: Build & run ---
echo "[+] Building Docker images..."
docker compose build --no-cache

echo "[+] Starting containers..."
docker compose up -d

echo "[+] Done. Use 'docker compose logs -f' to follow the logs."
