FROM eclipse-temurin:8-jre

# Install dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    tar \
    iproute2 \
    mariadb-server \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/shso

# Download SmartFoxServer Pro 1.6.6
# URL redirects to a tar.gz
RUN curl -L -o SFSPRO_linux64.tar.gz https://www.smartfoxserver.com/download/get/77

# Create directories for the two server instances
RUN mkdir -p sf-game sf-notification

# Extract SFS into both directories
# We use -k to keep existing files if any (though unlikely here), but mostly just standard extraction
RUN tar -xf SFSPRO_linux64.tar.gz --strip-components=1 -C sf-game \
    && tar -xf SFSPRO_linux64.tar.gz --strip-components=1 -C sf-notification \
    && rm SFSPRO_linux64.tar.gz

# Clone the SHUSD server repo to get the game logic
RUN git clone https://github.com/SHSUnderground/shso-server.git /tmp/shso-repo

# Overlay the custom server files onto both instances
# This overwrites the default SFS configuration and adds the extension logic
RUN cp -r /tmp/shso-repo/* sf-game/ \
    && cp -r /tmp/shso-repo/* sf-notification/ \
    && rm -rf /tmp/shso-repo

# Overwrite the sample DB with our sanitized local version (removes CREATE DATABASE/USE shso)
COPY ./SHSO_sample_DB.sql sf-game/SHSO_sample_DB.sql

# Fix permissions for the server binaries
RUN chmod +x sf-game/Server/sfs sf-notification/Server/sfs

# Setup Pterodactyl User
RUN useradd -m -d /home/container container

# Ensure all files in /opt/shso are owned by the container user
# This fixes "Permission denied" errors during copy
RUN chown -R container:container /opt/shso

USER container
ENV USER=container HOME=/home/container

WORKDIR /home/container

COPY ./entrypoint.sh /entrypoint.sh

CMD ["/bin/bash", "/entrypoint.sh"]
