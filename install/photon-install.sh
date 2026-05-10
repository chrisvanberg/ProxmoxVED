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
mkdir -p /opt/photon/dumps

cat <<EOF >/opt/photon/.env
PHOTON_REGIONS=europe/belgium,africa/northern-africa
REVERSE_ONLY=true
PHOTON_LISTEN_IP=0.0.0.0
PHOTON_LISTEN_PORT=2322
JAVA_OPTS=-Xmx2G
EOF
msg_ok "Set up Photon"

source /opt/photon/.env
BASE_URL="https://download1.graphhopper.com/public"
IFS=',' read -ra REGIONS <<<"$PHOTON_REGIONS"
DUMP_FILES=()

for region in "${REGIONS[@]}"; do
  region_name="${region##*/}"
  dump_url="${BASE_URL}/${region}/photon-dump-${region_name}-1.0-latest.jsonl.zst"
  dump_file="/opt/photon/dumps/${region_name}.jsonl.zst"
  md5_file="/opt/photon/dumps/${region_name}.md5"
  DUMP_FILES+=("$dump_file")

  remote_md5=$(curl -fsSL "${dump_url}.md5" | awk '{print $1}')
  if [[ -f "$dump_file" && -f "$md5_file" ]] && [[ "$(cat "$md5_file")" == "$remote_md5" ]]; then
    msg_ok "Dump ${region_name} already up-to-date, skipping"
    continue
  fi

  msg_info "Downloading ${region_name} data"
  stop_spinner
  echo ""
  download_with_progress "$dump_url" "$dump_file"
  set +o pipefail
  echo "$remote_md5" >"$md5_file"
  msg_ok "Downloaded ${region_name} data"
done

msg_info "Importing Photon Data"
stop_spinner
echo ""
IMPORT_ARGS="-import-file - -data-dir /opt/photon"
[[ "$REVERSE_ONLY" == "true" ]] && IMPORT_ARGS="$IMPORT_ARGS -reverse-only"
$STD bash -c "cat ${DUMP_FILES[*]} | zstd --stdout -d | java $JAVA_OPTS -jar /opt/photon/photon.jar import $IMPORT_ARGS"
rm -rf /opt/photon/dumps
msg_ok "Imported Photon Data"

msg_info "Creating Data Update Script"
cat <<'EOF' >/opt/photon/update-data.sh
#!/usr/bin/env bash
set -euo pipefail

source /opt/photon/.env

BASE_URL="https://download1.graphhopper.com/public"
IFS=',' read -ra REGIONS <<<"$PHOTON_REGIONS"

mkdir -p /opt/photon/dumps
DUMP_FILES=()

for region in "${REGIONS[@]}"; do
  region_name="${region##*/}"
  dump_url="${BASE_URL}/${region}/photon-dump-${region_name}-1.0-latest.jsonl.zst"
  dump_file="/opt/photon/dumps/${region_name}.jsonl.zst"
  md5_file="/opt/photon/dumps/${region_name}.md5"
  DUMP_FILES+=("$dump_file")

  remote_md5=$(curl -fsSL "${dump_url}.md5" | awk '{print $1}')
  if [[ -f "$dump_file" && -f "$md5_file" ]] && [[ "$(cat "$md5_file")" == "$remote_md5" ]]; then
    echo "${region_name}: already up-to-date, skipping"
    continue
  fi

  echo "Downloading ${region_name}..."
  curl -fL# -o "$dump_file" "$dump_url"
  echo "$remote_md5" >"$md5_file"
done

echo "Stopping Photon service..."
systemctl stop photon

echo "Removing old data..."
rm -rf /opt/photon/photon_data

IMPORT_ARGS="-import-file - -data-dir /opt/photon"
if [[ "${REVERSE_ONLY:-true}" == "true" ]]; then
  IMPORT_ARGS="$IMPORT_ARGS -reverse-only"
fi

echo "Importing data (reverse-only: ${REVERSE_ONLY:-true})..."
cat "${DUMP_FILES[@]}" | zstd --stdout -d | \
  java ${JAVA_OPTS:--Xmx2G} -jar /opt/photon/photon.jar import $IMPORT_ARGS

rm -rf /opt/photon/dumps

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
