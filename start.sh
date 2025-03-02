#!/usr/bin/env bash
#
# start.sh
# Dynamically sets up:
#   - docker-compose.yml (which ports to map for caddy)
#   - caddy/Caddyfile (which ports to listen on).
#
# Behavior:
#   - If one or more domains are specified:
#       * For each domain, unify all "TLS" ports (443,8443,9443,10443, etc.) into ONE block (space-separated addresses),
#         using the same Let's Encrypt certificate (ACME).
#       * All remaining ports become plain HTTP, domain:port.
#   - If NO domain is given:
#       * All TLS ports go into one block with tls internal, e.g. :443 :8443 :9443.
#       * All other ports are plain HTTP.
#
# This way there's only one site block for each domain's TLS ports, avoiding
# "hostname appears in more than one automation policy" and also avoiding
# commas in site addresses.
#
# EXAMPLES:
#   # Single domain, user ports: 80,443,8443 => unify 443 & 8443:
#   # "login.secarius.fr:443 login.secarius.fr:8443 { ... }"
#   ./start.sh -p "80,443,8443" -d "login.secarius.fr"
#
#   # Multiple domains, ports: 443,8080,8443 => domain1 + domain2 each get:
#   # "domain1.com:443 domain1.com:8443 { tls ... }" + domain1.com:8080 { plain }
#   # "domain2.org:443 domain2.org:8443 { tls ... }" + domain2.org:8080 { plain }
#   ./start.sh -p "443,8080,8443" -d domain1.com -d domain2.org
#
#   # No domains => all TLS ports => internal, all other => plain
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
  echo "[+] No domains specified -> unify TLS ports with 'tls internal'."
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
  matched=false
  for t in "${ALL_TLS_PORTS[@]}"; do
    if [[ "$p" == "$t" ]]; then
      TLS_PORTS+=( "$p" )
      matched=true
      break
    fi
  done
  if [ "$matched" = false ]; then
    HTTP_PORTS+=( "$p" )
  fi
done

echo "[+] TLS ports: ${TLS_PORTS[*]}"
echo "[+] HTTP ports: ${HTTP_PORTS[*]}"

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
# If domains -> for each domain, unify all TLS ports in a single site block (space separated).
# e.g. "login.secarius.fr:443 login.secarius.fr:8443 { tls admin@login.secarius.fr ... }"
# Then each HTTP port => "login.secarius.fr:80" plain.
#
# If NO domains -> unify all TLS ports in one block with internal TLS, e.g. ":443 :8443 :9443"
# plus plain for other ports, e.g. ":80" etc.
#############################################################

if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  # We have domains
  # Build a space-separated set of addresses for each domain's TLS ports
  for domain in "${DOMAINS[@]}"; do
    # 1) TLS ports block
    if [[ ${#TLS_PORTS[@]} -gt 0 ]]; then
      SITE_TLS_ADDRS=""
      for p in "${TLS_PORTS[@]}"; do
        SITE_TLS_ADDRS+="${domain}:${p}"
        # add "," if not last
        [[ "$p" != "${TLS_PORTS[-1]}" ]] && SITE_TLS_ADDRS+=", " 
      done
      # Trim
      SITE_TLS_ADDRS="$(echo "$SITE_TLS_ADDRS" | xargs)"

      cat >> caddy/Caddyfile <<EOF

$SITE_TLS_ADDRS {
    tls admin@${domain}
    reverse_proxy stolypote:65111
}
EOF
    fi

  done
else
  # No domains -> unify TLS ports with "tls internal"
  if [[ ${#TLS_PORTS[@]} -gt 0 ]]; then
    SITE_TLS_ADDRS=""
    for p in "${TLS_PORTS[@]}"; do
      SITE_TLS_ADDRS+=":${p} "
    done
    SITE_TLS_ADDRS="$(echo "$SITE_TLS_ADDRS" | xargs)" # trim

    cat >> caddy/Caddyfile <<EOF

$SITE_TLS_ADDRS {
    tls internal
    reverse_proxy stolypote:65111
}
EOF
  fi

  
fi

# HTTP ports
for p in "${HTTP_PORTS[@]}"; do
  cat >> caddy/Caddyfile <<EOF

:${p} {
    reverse_proxy stolypote:65111
}
EOF
done

echo "[+] Created caddy/Caddyfile."

# --- Step 3: Build & run ---
echo "[+] Building Docker images..."
#docker compose build --no-cache

echo "[+] Starting containers..."
#docker compose up -d

echo "[+] Done. Use 'docker compose logs -f' to watch logs."