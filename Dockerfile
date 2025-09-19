# Use the Ubuntu 24.04 LTS release as the base
FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies for the script, including dos2unix
RUN apt-get update && apt-get install -y \
    wget \
    p7zip-full \
    xorriso \
    isolinux \
    dos2unix \
    plocate \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy the build script into the container
COPY create_autoinstall_iso.sh /usr/local/bin/create_autoinstall_iso.sh

# Clean the script of any Windows line endings and make it executable
RUN dos2unix /usr/local/bin/create_autoinstall_iso.sh && \
    chmod +x /usr/local/bin/create_autoinstall_iso.sh

# Create a mount point for the user's files
RUN mkdir /data
VOLUME /data

# Set the main working directory inside the container
WORKDIR /data

# Set the script as the default command to run
ENTRYPOINT ["create_autoinstall_iso.sh"]
