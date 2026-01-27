#!/bin/bash

# SHSO Entrypoint Script for Pterodactyl

cd /home/container

# -----------------------------------------------------------------------------
# 1. File Synchronization
# -----------------------------------------------------------------------------
# Copy server files from the image to the volume if they don't exist.
# We do this for both 'sf-game' and 'sf-notification'.

copy_if_missing() {
    local SRC="/opt/shso/$1"
    local DST="/home/container/$1"
    
    if [ ! -d "$DST" ]; then
        echo "Initializing $1..."
        cp -r "$SRC" "$DST"
    else
        echo "$1 exists, checking for missing critical files..."
        # Optional: We could update specific binaries here if we wanted to enforce updates
        # e.g., cp "$SRC/Server/sfs" "$DST/Server/sfs"
    fi
}

copy_if_missing "sf-game"
copy_if_missing "sf-notification"

# Make the database sample file easily accessible
if [ -f "/home/container/sf-game/SHSO_sample_DB.sql" ] && [ ! -f "/home/container/SHSO_sample_DB.sql" ]; then
    cp "/home/container/sf-game/SHSO_sample_DB.sql" "/home/container/SHSO_sample_DB.sql"
fi

# Ensure binaries are executable
chmod +x sf-game/Server/sfs
chmod +x sf-notification/Server/sfs

# -----------------------------------------------------------------------------
# 2. Configuration
# -----------------------------------------------------------------------------
# Configure Database Connection in config.xml for both servers.
# We use sed to replace standard placeholders or existing values.

# Env vars provided by Pterodactyl:
# DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
# GAME_PORT, NOTIF_PORT

configure_xml() {
    local FOLDER="$1"
    local SERVER_PORT="$2"
    local FILE="$FOLDER/Server/config.xml"
    
    if [ -f "$FILE" ]; then
        echo "Configuring $FILE with port $SERVER_PORT..."
        
        # Replace Connection String
        # Pattern: <ConnectionString>jdbc:mysql://[host]:[port]/[database]...</ConnectionString>
        
        sed -i "s|<ConnectionString>.*</ConnectionString>|<ConnectionString>jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_DATABASE}?useSSL=false</ConnectionString>|g" "$FILE"
        sed -i "s|<UserName>.*</UserName>|<UserName>${DB_USERNAME}</UserName>|g" "$FILE"
        sed -i "s|<Password>.*</Password>|<Password>${DB_PASSWORD}</Password>|g" "$FILE"

        # Update Server Port
        # Pattern: <ServerPort>9339</ServerPort>
        sed -i "s|<ServerPort>.*</ServerPort>|<ServerPort>${SERVER_PORT}</ServerPort>|g" "$FILE"
        
        echo "Updated configuration for $FOLDER."
    else
        echo "WARNING: Config file $FILE not found!"
    fi
}

configure_xml "sf-game" "${GAME_PORT:-9339}"
configure_xml "sf-notification" "${NOTIF_PORT:-9389}"

# -----------------------------------------------------------------------------
# 3. Startup
# -----------------------------------------------------------------------------
echo "Starting SHSO Servers..."

# Start Notification Server in Background
echo "Launching Notification Server..."
cd /home/container/sf-notification/Server
./sfs start
# Give it a moment
sleep 5

# Start Game Server in Foreground (console mode if supported, or start and tail logs)
echo "Launching Game Server..."
cd /home/container/sf-game/Server

# Try to run in console mode to keep container alive and show logs
# If 'console' is not a valid command for this version of SFS, we might fail.
# Standard SFS Pro 1.6.x 'sfs' script usually supports 'console'.
./sfs console

# If 'console' falls through or isn't supported, we fallback to tailing logs
if [ $? -ne 0 ]; then
    echo "Console mode failed or exited. Attempting standard start and log tail..."
    ./sfs start
    
    # Tail both logs to keep container alive and visible
    tail -f ../logs/smartfox.log ../../../sf-notification/Server/logs/smartfox.log
fi
