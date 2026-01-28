#!/bin/bash

# SHSO Entrypoint Script for Pterodactyl

cd /home/container

# -----------------------------------------------------------------------------
# 0. Integrated Database Setup (Embedded MariaDB)
# -----------------------------------------------------------------------------
setup_internal_db() {
    echo "--- Configuring Internal Database ---"
    export MYSQL_HOME=/home/container/database
    mkdir -p $MYSQL_HOME

    if [ ! -d "$MYSQL_HOME/mysql" ]; then
        echo "Initializing MariaDB data directory..."
        INSTALLER="mysql_install_db"
        if command -v mariadb-install-db >/dev/null 2>&1; then
            INSTALLER="mariadb-install-db"
        fi
        
        $INSTALLER --datadir="$MYSQL_HOME" --auth-root-authentication-method=normal --skip-test-db --basedir=/usr --force >/dev/null 2>&1
        
        if [ ! -d "$MYSQL_HOME/mysql" ]; then
            echo "First initialization failed! Retrying with verbose output..."
            $INSTALLER --datadir="$MYSQL_HOME" --auth-root-authentication-method=normal --skip-test-db --basedir=/usr --force --verbose
        fi
    fi

    echo "Starting MariaDB..."
    /usr/bin/mysqld_safe --datadir="$MYSQL_HOME" --pid-file="$MYSQL_HOME/mariadb.pid" --socket="$MYSQL_HOME/mysql.sock" --port=3306 --user=container --no-watch --log-error="$MYSQL_HOME/mariadb.err" --skip-syslog --skip-networking=0
    
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

    mysql --socket="$MYSQL_HOME/mysql.sock" -u root -e "CREATE DATABASE IF NOT EXISTS shso;"
    mysql --socket="$MYSQL_HOME/mysql.sock" -u root -e "CREATE USER IF NOT EXISTS 'shso'@'localhost' IDENTIFIED BY 'shso';"
    mysql --socket="$MYSQL_HOME/mysql.sock" -u root -e "GRANT ALL PRIVILEGES ON shso.* TO 'shso'@'localhost';"
    mysql --socket="$MYSQL_HOME/mysql.sock" -u root -e "FLUSH PRIVILEGES;"

    if ! mysql --socket="$MYSQL_HOME/mysql.sock" -u shso -pshso -D shso -e "DESCRIBE users;" >/dev/null 2>&1; then
        echo "Empty database detected. Importing initial schema..."
        if [ -f "/home/container/sf-game/SHSO_sample_DB.sql" ]; then
            mysql --socket="$MYSQL_HOME/mysql.sock" -u shso -pshso shso < "/home/container/sf-game/SHSO_sample_DB.sql"
            echo "Import successful."
        elif [ -f "/home/container/SHSO_sample_DB.sql" ]; then
             mysql --socket="$MYSQL_HOME/mysql.sock" -u shso -pshso shso < "/home/container/SHSO_sample_DB.sql"
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
copy_if_missing() {
    local SRC="/opt/shso/$1"
    local DST="/home/container/$1"
    
    if [ ! -d "$DST" ]; then
        echo "Initializing $1..."
        cp -r "$SRC" "$DST"
    fi
}

copy_if_missing "sf-game"
copy_if_missing "sf-notification"

# Ensure binaries/scripts are executable
chmod +x sf-game/Server/sfs sf-game/Server/start.sh
chmod +x sf-notification/Server/sfs sf-notification/Server/start.sh

# -----------------------------------------------------------------------------
# 2. Configuration & Fixes
# -----------------------------------------------------------------------------

# A. Fix Python Paths (Crucial for SHSO)
# The server scripts use hardcoded relative paths that break in some contexts.
# We replace them with absolute paths to the container home.
echo "Applying Python path fixes..."
SEARCH_PATH="/home/container/sf-game/Server/webserver/webapps/root"
if [ -d "$SEARCH_PATH" ]; then
    # Fix 'users' scripts
    if [ -d "$SEARCH_PATH/rasp/users" ]; then
        find "$SEARCH_PATH/rasp/users" -type f -name "*.py" -print0 | xargs -0 sed -i "s|sf-game/Server/webserver/webapps/root|/home/container/sf-game/Server/webserver/webapps/root|g"
    fi
    # Fix 'data/json' scripts
    if [ -d "$SEARCH_PATH/rasp/data/json" ]; then
        find "$SEARCH_PATH/rasp/data/json" -type f -name "*.py" -print0 | xargs -0 sed -i "s|sf-game/Server/webserver/webapps/root|/home/container/sf-game/Server/webserver/webapps/root|g"
    fi
else
    echo "WARNING: Webserver root not found at $SEARCH_PATH"
fi

# B. Configure XMLs (Ports & DB)
configure_xml() {
    local FOLDER="$1"
    local SERVER_PORT="$2"
    local FILE="/home/container/$FOLDER/Server/config.xml"
    
    if [ -f "$FILE" ]; then
        echo "Configuring $FILE with port $SERVER_PORT..."
        
        # Configure DB Connection (Always Localhost/Internal)
        sed -i "s|<ConnectionString>.*</ConnectionString>|<ConnectionString>jdbc:mysql://127.0.0.1:3306/shso?useSSL=false\&amp;allowPublicKeyRetrieval=true</ConnectionString>|g" "$FILE"
        sed -i "s|<UserName>.*</UserName>|<UserName>shso</UserName>|g" "$FILE"
        sed -i "s|<Password>.*</Password>|<Password>shso</Password>|g" "$FILE"

        # Configure Server Port
        sed -i "s|<ServerPort>.*</ServerPort>|<ServerPort>$SERVER_PORT</ServerPort>|g" "$FILE"

        echo "Updated configuration for $FOLDER."
    else
        echo "WARNING: Config file $FILE not found!"
    fi
}

configure_xml "sf-game" "${GAME_PORT:-9339}"
configure_xml "sf-notification" "${NOTIF_PORT:-9389}"

# C. Configure Web Port (sf-game only)
# We update jetty.xml to use the requested WEB_PORT
WEB_PORT="${WEB_PORT:-8080}"
JETTY_XML="/home/container/sf-game/Server/webserver/cfg/jetty.xml"

if [ -f "$JETTY_XML" ]; then
    echo "Configuring Web Server port to $WEB_PORT..."
    # Jetty XML uses <SystemProperty name="jetty.port" default="80"/>
    # We can either replace the default value OR rely on -Djetty.port in the start command.
    # Replacing the default is safer if the start command doesn't propagate args correctly.
    sed -i "s|name=\"jetty.port\" default=\"[0-9]*\"|name=\"jetty.port\" default=\"$WEB_PORT\"|g" "$JETTY_XML"
fi

# -----------------------------------------------------------------------------
# 3. Startup
# -----------------------------------------------------------------------------
echo "Starting SHSO Servers..."

# Start Notification Server in Background
echo "Launching Notification Server..."
cd /home/container/sf-notification/Server
# We use nohup to ensure it stays running in background
nohup ./start.sh > ../logs/notification_start.log 2>&1 &
NOTIF_PID=$!
echo "Notification Server PID: $NOTIF_PID"
sleep 5

# Start Game Server in Foreground
echo "Launching Game Server..."
cd /home/container/sf-game/Server

# Run start.sh directly.
# Since start.sh usually ends with the java command, it will take over this process
# if we exec it. However, we want to trap signals if possible, but for simplicity
# and compatibility with 'start.sh', we will just run it.
# Note: start.sh in the repo is: java ... it.gotoandplay.smartfoxserver.SmartFoxServer
# It logs to console? The config says <ConsoleLoggingLevel>INFO</ConsoleLoggingLevel>.

# If we just run ./start.sh, it should output to stdout, which Pterodactyl picks up.
# We also want to pass -Djetty.port just in case, though we edited the xml.
# But start.sh might not accept arguments appended to it if it doesn't use "$@".
# Let's check start.sh content again.
# It is: java ... SmartFoxServer
# It does NOT use "$@". So passing args to ./start.sh won't work unless we edit start.sh.
# But we edited jetty.xml default, so we are good.

exec ./start.sh
