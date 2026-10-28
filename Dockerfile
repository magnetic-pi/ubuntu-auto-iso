# Builder for the autoinstall ISO and the Raspberry Pi image.
# You don't need to build this yourself: ./build.sh does it automatically.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

#   xorriso      read and rewrite the ISO
#   mtools       edit the Pi image's FAT boot partition without mounting it
#   xz-utils     unpack and repack the Pi image
#   cloud-init   validate the generated configs before the slow image steps
#   openssl      `openssl passwd -6` for generating PASSWORD_HASH
#   dos2unix     tolerate scripts checked out with Windows line endings
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        xorriso \
        mtools \
        xz-utils \
        cloud-init \
        openssl \
        dos2unix \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ /opt/builder/scripts/
RUN find /opt/builder -name '*.sh' -exec dos2unix -q {} + \
    && chmod +x /opt/builder/scripts/*.sh

# The project folder (config/, downloads/, output/) is mounted here.
WORKDIR /data
ENTRYPOINT ["/opt/builder/scripts/entrypoint.sh"]
CMD ["all"]
