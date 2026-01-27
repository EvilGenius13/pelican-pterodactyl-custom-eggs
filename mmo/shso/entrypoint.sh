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
# 2.5. Wrapper Configuration (Fix JVM Path)
# -----------------------------------------------------------------------------
# Ensure the wrapper uses the system 'java' command instead of a bundled/relative one.
fix_wrapper_conf() {
    local FOLDER="$1"
    local CONF="$FOLDER/Server/conf/wrapper.conf"
    
    if [ -f "$CONF" ]; then
        echo "Updating Java path in $CONF..."
        
        # Get absolute path to Java to prevent "No such file or directory" errors
        # The wrapper sometimes struggles with just 'java' if PATH isn't inherited perfectly
        local JAVA_PATH=$(which java)
        
        if [ -z "$JAVA_PATH" ]; then
            JAVA_PATH="java" # Fallback
        fi
        
        # Force wrapper to use the system java executable
        # We match broadly to catch commented out or weirdly formatted lines
        sed -i "s|^.*wrapper.java.command=.*|wrapper.java.command=${JAVA_PATH}|g" "$CONF"
    else
        echo "WARNING: Wrapper config $CONF not found!"
    fi
}

fix_wrapper_conf "sf-game"
fix_wrapper_conf "sf-notification"

# -----------------------------------------------------------------------------
# 2.8. Database Initialization
# -----------------------------------------------------------------------------
# Check if the database is populated. If not, try to import the sample DB.
init_db() {
    echo "Checking database state..."
    # Try to list the 'users' table. Default SHSO DB has a 'users' table.
    # We suppress output; we just care about the exit code.
    if mysql -u"${DB_USERNAME}" -p"${DB_PASSWORD}" -h"${DB_HOST}" "${DB_DATABASE}" -e "DESCRIBE users;" >/dev/null 2>&1; then
        echo "Database check: 'users' table detected. Skipping import."
    else
        echo "Database check: Table 'users' not found. Attempting to populate database..."
        
        if [ -f "/home/container/SHSO_sample_DB.sql" ]; then
             echo "Importing SHSO_sample_DB.sql..."
             # Process the import
             mysql -u"${DB_USERNAME}" -p"${DB_PASSWORD}" -h"${DB_HOST}" "${DB_DATABASE}" < "/home/container/SHSO_sample_DB.sql"
             
             if [ $? -eq 0 ]; then
                echo "Database import successful!"
             else
                echo "ERROR: Database import failed. Check credentials or connection."
             fi
        else
             echo "WARNING: /home/container/SHSO_sample_DB.sql not found. Cannot auto-setup database."
        fi
    fi
}

# Run the DB check (requires mariadb-client installed in Dockerfile)
if command -v mysql >/dev/null 2>&1; then
    init_db
else
    echo "WARNING: 'mysql' command not found, skipping DB auto-init."
fi

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
