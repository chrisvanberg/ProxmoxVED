#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: chrisvanberg <contact@chrisvanberg.com>
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/komoot/photon

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  pv \
  zstd
msg_ok "Installed Dependencies"

JAVA_VERSION="21" setup_java

fetch_and_deploy_gh_release "photon" "komoot/photon" "singlefile" "latest" "/opt/photon" "photon-*.jar"

msg_info "Setting up Photon"
mv /opt/photon/photon /opt/photon/photon.jar

cat <<EOF >/opt/photon/.env
COUNTRY_CODES=BE
REVERSE_ONLY=true
PHOTON_LISTEN_IP=0.0.0.0
PHOTON_LISTEN_PORT=2322
JAVA_OPTS=-Xmx2G
EOF
msg_ok "Set up Photon"

DUMP_URL="https://download1.graphhopper.com/public/photon-dump-planet-1.0-latest.jsonl.zst"
DUMP_FILE="/opt/photon/photon-dump.jsonl.zst"
DUMP_MD5_FILE="/opt/photon/photon-dump.md5"

REMOTE_MD5=$(curl -fsSL "${DUMP_URL}.md5" | awk '{print $1}')
if [[ -f "$DUMP_FILE" && -f "$DUMP_MD5_FILE" ]] && [[ "$(cat "$DUMP_MD5_FILE")" == "$REMOTE_MD5" ]]; then
  msg_ok "Photon Data dump already present and up-to-date, skipping download"
else
  msg_info "Downloading Photon Data (this will take a while)"
  stop_spinner
  echo ""
  download_with_progress "$DUMP_URL" "$DUMP_FILE"
  echo "$REMOTE_MD5" >"$DUMP_MD5_FILE"
  msg_ok "Downloaded Photon Data"
fi

msg_info "Importing Photon Data"
source /opt/photon/.env
IMPORT_ARGS="-import-file - -data-dir /opt/photon"
[[ -n "$COUNTRY_CODES" ]] && IMPORT_ARGS="$IMPORT_ARGS -country-codes $COUNTRY_CODES"
[[ "$REVERSE_ONLY" == "true" ]] && IMPORT_ARGS="$IMPORT_ARGS -reverse-only"
$STD bash -c "zstd --stdout -d /opt/photon/photon-dump.jsonl.zst | java $JAVA_OPTS -jar /opt/photon/photon.jar import $IMPORT_ARGS"
rm -f /opt/photon/photon-dump.jsonl.zst
msg_ok "Imported Photon Data"

msg_info "Creating Data Update Script"
cat <<'EOF' >/opt/photon/update-data.sh
#!/usr/bin/env bash
set -euo pipefail

source /opt/photon/.env

DUMP_URL="https://download1.graphhopper.com/public/photon-dump-planet-1.0-latest.jsonl.zst"
DUMP_FILE="/opt/photon/photon-dump.jsonl.zst"
DUMP_MD5_FILE="/opt/photon/photon-dump.md5"

REMOTE_MD5=$(curl -fsSL "${DUMP_URL}.md5" | awk '{print $1}')
if [[ -f "$DUMP_FILE" && -f "$DUMP_MD5_FILE" ]] && [[ "$(cat "$DUMP_MD5_FILE")" == "$REMOTE_MD5" ]]; then
  echo "Photon Data dump already present and up-to-date, skipping download"
else
  echo "Downloading latest Photon dump..."
  curl -fL# -o "$DUMP_FILE" "$DUMP_URL"
  echo "$REMOTE_MD5" >"$DUMP_MD5_FILE"
fi

echo "Stopping Photon service..."
systemctl stop photon

echo "Removing old data..."
rm -rf /opt/photon/photon_data

IMPORT_ARGS="-import-file - -data-dir /opt/photon"
if [[ -n "${COUNTRY_CODES:-}" ]]; then
  IMPORT_ARGS="$IMPORT_ARGS -country-codes $COUNTRY_CODES"
fi
if [[ "${REVERSE_ONLY:-true}" == "true" ]]; then
  IMPORT_ARGS="$IMPORT_ARGS -reverse-only"
fi

echo "Importing data with country codes: ${COUNTRY_CODES:-all} (reverse-only: ${REVERSE_ONLY:-true})..."
zstd --stdout -d /opt/photon/photon-dump.jsonl.zst | \
  java ${JAVA_OPTS:--Xmx2G} -jar /opt/photon/photon.jar import $IMPORT_ARGS

rm -f /opt/photon/photon-dump.jsonl.zst

echo "Starting Photon service..."
systemctl start photon
echo "Done!"
EOF
chmod +x /opt/photon/update-data.sh
msg_ok "Created Data Update Script"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/photon.service
[Unit]
Description=Photon Geocoder
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/photon
EnvironmentFile=/opt/photon/.env
ExecStart=/bin/sh -c 'exec java \$JAVA_OPTS -jar /opt/photon/photon.jar serve -data-dir /opt/photon -listen-ip \$PHOTON_LISTEN_IP -listen-port \$PHOTON_LISTEN_PORT'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now photon
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
