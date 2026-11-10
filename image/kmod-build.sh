#!/bin/sh
# Build bcachefs.ko from Kent's tree against Alpine linux-lts headers.
# Runs INSIDE the Alpine chroot on the Debian builder guest.
# Source: bcachefs-tools-<VER>.tar.zst from evilpiepirate.org.
# See V03-STEP2-REPORT.md (F16) for the full recipe.
#!/bin/sh
set -e
set -x
cd /root/bcachefs-tools-1.39.7
rm -rf /root/bcachefs-dkms
mkdir -p /root/bcachefs-dkms/src/fs/bcachefs
tar -C fs --exclude='*.o' --exclude='*.d' --exclude='.*.cmd' -cf - . | tar -C /root/bcachefs-dkms/src/fs/bcachefs -xf -
cp -a dkms/Makefile /root/bcachefs-dkms/Makefile
echo '#define bcachefs_version "1.39.7"' > /root/bcachefs-dkms/src/fs/bcachefs/version.h
cp -a dkms/module-version.c /root/bcachefs-dkms/src/fs/bcachefs/
env BCACHEFS_DKMS=1 make -C /usr/src/linux-headers-6.18.62-0-lts M=/root/bcachefs-dkms modules
echo "BUILD-EXIT:$?"
