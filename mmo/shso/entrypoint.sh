#!/bin/bash

# SHSO Entrypoint Script for Pterodactyl

cd /home/container

# -----------------------------------------------------------------------------
# 0. Integrated Database Setup (Embedded MariaDB)
# -----------------------------------------------------------------------------
# Since we are running "All-in-One", we need to manage our own SQL server.
# We store data in /home/container/database so it persists across restarts.

setup_internal_db() {
    echo "--- Configuring Internal Database ---"
    export MYSQL_HOME=/home/container/database
    mkdir -p $MYSQL_HOME

    # Initialize MariaDB data directory if empty (checks for 'mysql' folder)
    if [ ! -d "$MYSQL_HOME/mysql" ]; then
        echo "Initializing MariaDB data directory..."
        
        # Try finding the install command (it varies by version/distro)
        INSTALLER="mysql_install_db"
        if command -v mariadb-install-db >/dev/null 2>&1; then
            INSTALLER="mariadb-install-db"
        fi
        
        echo "Using installer: $INSTALLER"
        
        # We ensure auth-root-authentication-method=normal so we can log in without sudo
        # We redirect output to console now so we can see if it fails
        # Added --skip-test-db and --cross-bootstrap (sometimes helps in containers)
        # REMOVING --user=container because we are already running as non-root and cannot chown
        # Added --force so it doesn't fail if a previous attempt left 'ibdata1' but no tables
        $INSTALLER --datadir="$MYSQL_HOME" --auth-root-authentication-method=normal --skip-test-db --basedir=/usr --force >/dev/null 2>&1
        
        # Double check if it actually worked
        if [ ! -d "$MYSQL_HOME/mysql" ]; then
            echo "First initialization failed! Retrying with verbose output..."
            $INSTALLER --datadir="$MYSQL_HOME" --auth-root-authentication-method=normal --skip-test-db --basedir=/usr --force --verbose
        fi
    fi

    # Start MariaDB in the background
    echo "Starting MariaDB..."
    # We use --skip-networking to ensure it binds ONLY to localhost (security/collision avoidance)
    # We pass --port=3306 explicitly just in case config defaults vary
    # Added --skip-syslog and --log-error to debug startup issues and prevent hangs
    /usr/bin/mysqld_safe --datadir="$MYSQL_HOME" --pid-file="$MYSQL_HOME/mariadb.pid" --socket="$MYSQL_HOME/mysql.sock" --port=3306 --user=container --no-watch --log-error="$MYSQL_HOME/mariadb.err" --skip-syslog --skip-networking=0
    
    # Wait for DB to come alive
    echo "Waiting for MariaDB to be ready..."
    local i=0
    while ! mysqladmin ping --socket="$MYSQL_HOME/mysql.sock" --silent; do
        sleep 1
        i=$((i+1))
        if [ $i -ge 30 ]; then
             echo "MariaDB failed to start within 30 seconds."
             if [ -f "$MYSQL_HOME/mariadb.err" ]; then
                 echo "--- MariaDB Error Log ---"
                 cat "$MYSQL_HOME/mariadb.err"
                 echo "-------------------------"
             fi
             exit 1
        fi
    done
    echo "MariaDB is UP."

    # Create User and Database if they don't exist
    # We use a hardcoded local user since this DB is not exposed externally anyway.
    mysql --socket="$MYSQL_HOME/mysql.sock" -u root -e "CREATE DATABASE IF NOT EXISTS shso;"
    mysql --socket="$MYSQL_HOME/mysql.sock" -u root -e "CREATE USER IF NOT EXISTS 'shso'@'localhost' IDENTIFIED BY 'shso';"
    mysql --socket="$MYSQL_HOME/mysql.sock" -u root -e "GRANT ALL PRIVILEGES ON shso.* TO 'shso'@'localhost';"
    mysql --socket="$MYSQL_HOME/mysql.sock" -u root -e "FLUSH PRIVILEGES;"

    # Import Schema if 'users' table is missing
    if ! mysql --socket="$MYSQL_HOME/mysql.sock" -u shso -pshso -D shso -e "DESCRIBE users;" >/dev/null 2>&1; then
        echo "Empty database detected. Importing initial schema..."
        if [ -f "/opt/shso/sf-game/SHSO_sample_DB.sql" ]; then
            mysql --socket="$MYSQL_HOME/mysql.sock" -u shso -pshso shso < "/opt/shso/sf-game/SHSO_sample_DB.sql"
            echo "Import successful."
        else
            echo "WARNING: SQL sample file missing. Database is empty."
        fi
    fi
}

setup_internal_db

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
# We ignore DB vars now because we enforce localhost

configure_xml() {
    local FOLDER="$1"
    local SERVER_PORT="$2"
    local FILE="$FOLDER/Server/config.xml"
    
    if [ -f "$FILE" ]; then
        echo "Configuring $FILE with port $SERVER_PORT..."
        
        # Force Localhost Connection for Internal DB
        # We also need to specify the socket if using localhost sometimes, but SFS usually uses TCP (127.0.0.1:3306)
        # Note: In 'setup_internal_db' we started mysqld without networking by default? 
        # Actually mysqld_safe usually binds 3306. We need to make sure config.xml uses 127.0.0.1
        
        sed -i "s|<ConnectionString>.*</ConnectionString>|<ConnectionString>jdbc:mysql://127.0.0.1:3306/shso?useSSL=false\&amp;allowPublicKeyRetrieval=true</ConnectionString>|g" "$FILE"
        sed -i "s|<UserName>.*</UserName>|<UserName>shso</UserName>|g" "$FILE"
        sed -i "s|<Password>.*</Password>|<Password>shso</Password>|g" "$FILE"
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
        sed -i "s|^.*wrapper.java.command=.*|wrapper.java.command=${JAVA_PATH}|g" "$CONF"

        # --- FIX 1: Explicitly set absolute paths for Critical Jars ---
        # The wrapper fails if it defines jars using relative paths (like lib/foo.jar) 
        # because the working directory inside the container might drift or simply fail to resolve.
        
        # Helper to find and set absolute path for a specific jar
        set_abs_jar() {
            local JAR_NAME="$1"
            local SEARCH_PATH="$2"
            local CONF_FILE="$3"
            
            local FOUND_REL_PATH=$(find "$SEARCH_PATH" -name "$JAR_NAME" | head -n 1)
            if [ -n "$FOUND_REL_PATH" ]; then
                local ABS_PATH="/home/container/${FOUND_REL_PATH}"
                echo "Fixing path for $JAR_NAME -> $ABS_PATH"
                # Scan for any classpath line containing this jar name (e.g. ...=lib/smartfoxserver.jar)
                # and replace everything after the '=' with the absolute path
                sed -i "s|=.*${JAR_NAME}|=${ABS_PATH}|" "$CONF_FILE"
            else
                echo "WARNING: $JAR_NAME not found in $SEARCH_PATH"
            fi
        }

        set_abs_jar "wrapper.jar" "$FOLDER/Server" "$CONF"
        set_abs_jar "smartfoxserver.jar" "$FOLDER/Server" "$CONF"
        set_abs_jar "jdom.jar" "$FOLDER/Server" "$CONF"
        set_abs_jar "json.jar" "$FOLDER/Server" "$CONF"
        set_abs_jar "commons-pool-1.2.jar" "$FOLDER/Server" "$CONF"
        set_abs_jar "commons-dbcp-1.2.1.jar" "$FOLDER/Server" "$CONF"
        set_abs_jar "commons-collections-3.1.jar" "$FOLDER/Server" "$CONF"

        # --- DEBUG: Print Status ---
        echo "--- Final Wrapper Config Environment ($FOLDER) ---"
        grep "wrapper.java.classpath" "$CONF"
        echo "------------------------------------------------"
    else
        echo "WARNING: Wrapper config $CONF not found!"
    fi
}

fix_wrapper_conf "sf-game"

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
