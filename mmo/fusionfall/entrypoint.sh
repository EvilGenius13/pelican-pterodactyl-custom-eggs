#!/bin/bash
cd /home/container

echo "Checking for game files..."

# Update Assets from the baked-in Docker image (/opt/openfusion)
# We overwrite these to ensure the server is always running the latest version provided by the egg.
cp /opt/openfusion/fusion /home/container/fusion
cp -r /opt/openfusion/tdata /home/container/
cp -r /opt/openfusion/sql /home/container/
cp -r /opt/openfusion/res /home/container/

# Restore Default Config ONLY if missing
if [ ! -f config.ini ]; then
    echo "Copying default config.ini..."
    cp /opt/openfusion/config.ini /home/container/config.ini
fi

chmod +x ./fusion

# ---------------------------------------------------------
# IP CONFIGURATION
# ---------------------------------------------------------
# Logic: Use the Announce IP if provided (for advanced setups), 
# otherwise default to the Panel's assigned external IP.
FINAL_IP=${SERVER_IP}

if [ ! -z "${ANNOUNCE_IP}" ]; then
    echo "Using Manual Announce IP: ${ANNOUNCE_IP}"
    FINAL_IP=${ANNOUNCE_IP}
else
    echo "Using Panel Default IP: ${FINAL_IP}"
fi

echo "Updating config.ini..."

# 1. Update Login Port
if [ ! -z "${LOGIN_PORT}" ]; then
    sed -i "/^\[login\]/,/^\[/ s/^port\s*=.*/port=${LOGIN_PORT}/" config.ini
fi

# 2. Update Shard Port
if [ ! -z "${SHARD_PORT}" ]; then
    sed -i "/^\[shard\]/,/^\[/ s/^port\s*=.*/port=${SHARD_PORT}/" config.ini
fi

# 3. Update IP Address (ExternalIP)
if [ ! -z "${FINAL_IP}" ]; then
   sed -i "/^\[shard\]/,/^\[/ s/^ip\s*=.*/ip=${FINAL_IP}/" config.ini
fi

# 4. Update Monitor Port
if [ ! -z "${MONITOR_PORT}" ]; then
    sed -i "/^\[monitor\]/,/^\[/ s/^port\s*=.*/port=${MONITOR_PORT}/" config.ini
    # Ensure it listens on all interfaces so the panel can reach it
    sed -i "/^\[monitor\]/,/^\[/ s/^listenip\s*=.*/listenip=0.0.0.0/" config.ini
fi

echo "Starting OpenFusion..."
exec ./fusion
