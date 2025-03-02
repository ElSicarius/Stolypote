#!/usr/bin/env bash
#
# start.sh
# Dynamically sets up:
#   - docker-compose.yml (which ports to map for caddy)
#   - caddy/Caddyfile (which ports to listen on; optionally domain-based TLS)
# Then builds & starts the Docker Compose stack.
#
# USAGE:
#   ./start.sh -p "80,443,8080" [-d "example.com"]
#   ./start.sh -p "3000-3010"   [-d "example.com"]
#   ./start.sh -f ports/top10.txt [-d "example.com"]
#
# EXAMPLE:
#   # from a file
#   echo "80" > ports/top10.txt
#   echo "443" >> ports/top10.txt
#   ./start.sh -f ports/top10.txt -d example.com
#
# NOTE:
#  - If a domain is given, Caddy tries to get real certificates on ports 80/443.
#  - If no domain is given, Caddy uses internal/self-signed cert for any TLS port.
#
set -e

# Default/empty
PORT_SPEC=""
PORT_FILE=""
DOMAIN=""

function usage() {
  echo "Usage: $0 [ -p \"port-spec\" | -f <port-file> ] [ -d <domain> ]"
  echo "  -p \"...\"   => comma list or a range (e.g. '80,443' or '3000-3010')"
  echo "  -f <file>   => file with one port per line (e.g. 'ports/top10.txt')"
  echo "  -d <domain> => e.g. 'example.com'"
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
      DOMAIN="$2"
      shift; shift
      ;;
    *)
      echo "[!] Unknown argument: $1"
      usage
      ;;
  esac
done

# Basic validation: user must supply either -p or -f
if [[ -z "$PORT_SPEC" && -z "$PORT_FILE" ]]; then
  echo "[!] You must provide ports with -p or -f"
  usage
fi

if [[ -n "$PORT_SPEC" && -n "$PORT_FILE" ]]; then
  echo "[!] Please specify EITHER -p or -f, not both."
  usage
fi

echo "[+] Domain: ${DOMAIN:-'(none)'}"

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

# --- Step 1: Generate docker-compose.yml. It has to be dynamic for the range of openned ports ---
cat > docker-compose.yml <<EOF
# version: '3.8' -- docker-compose file "version" is obsolete

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
# (Inside the container, caddy listens on the same port, or optionally you can do "80:80", "443:443")
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

# If user specified a domain, handle real certificates for 80/443
# We'll do a special block for domain:443 + a redirect from domain:80
if [[ -n "$DOMAIN" ]]; then
  cat >> caddy/Caddyfile <<EOF

# HTTP -> HTTPS redirect for the domain
:80 {
    @mydomain host ${DOMAIN}
    redir @mydomain https://${DOMAIN}{uri}
    # If something else hits port 80 but not the domain name, let's just pass to honeypot
    reverse_proxy honeypot:65111
}

# Let's Encrypt-protected site
${DOMAIN}:443 {
    tls {
        # By default, caddy uses ACME/Let's Encrypt
        # If you want DNS or EAB challenge, you'd configure it here
    }
    reverse_proxy honeypot:65111
}
EOF
fi

# For any other requested ports beyond 80/443, create generic blocks
# If domain is set and the port is e.g. 8443, we can also do domain:8443 with real certs
for p in "${UNIQUE_PORTS[@]}"; do
  # If domain was provided, we already handled 80/443 above
  if [[ "$p" == "80" || "$p" == "443" ]]; then
    # skip (already done if domain is used)
    if [[ -z "$DOMAIN" ]]; then
      # If no domain is provided, we define them as normal blocks
      if [[ "$p" == "443" ]]; then
        cat >> caddy/Caddyfile <<EOF

:${p} {
    tls internal
    reverse_proxy honeypot:65111
}
EOF
      else
        cat >> caddy/Caddyfile <<EOF

:${p} {
    reverse_proxy honeypot:65111
}
EOF
      fi
    fi
  else
    # For everything else: if domain is given and port is e.g. 8443, we might do domain:8443 with real cert
    if [[ -n "$DOMAIN" && "$p" == "8443" ]]; then
      cat >> caddy/Caddyfile <<EOF

${DOMAIN}:${p} {
    tls {
        # Let's Encrypt
    }
    reverse_proxy honeypot:65111
}
EOF
    else
      # fallback: internal cert
      cat >> caddy/Caddyfile <<EOF

:${p} {
    tls internal
    reverse_proxy honeypot:65111
}
EOF
    fi
  fi
done

echo "[+] Created caddy/Caddyfile."

# --- Step 3: Build & run ---
echo "[+] Building Docker images..."
docker compose build

echo "[+] Starting containers..."
docker compose up -d

echo "[+] Done. Use 'docker compose logs -f' to follow the logs."
