#!/bin/bash

# Create a chroot jail in 'BASEDIR' and user 'TESTUSER'
# Requires access to internet for download script l2chroot for copy shared libraries
# If you don't want access to ssh or auth with pub key so change shell user to rssh.

BASEDIR=/sftpdir/chroot
TESTUSER=testuser
set -x

# rssh
yum -y install rssh

# From: https://www.cyberciti.biz/tips/howto-linux-unix-rssh-chroot-jail-setup.html

# Create all required directories:
mkdir -p $BASEDIR
#mkdir -p $BASEDIR/home

mkdir -p $BASEDIR/{dev,etc,lib64,usr,bin}
mkdir -p $BASEDIR/usr/bin
mkdir -p $BASEDIR/usr/libexec/openssh

# Create $BASEDIR/dev/null:
mknod -m 666 $BASEDIR/dev/null c 1 3


# Copy required binary files to your jail directory $BASEDIR/bin and other locations:
cd $BASEDIR/usr/bin
#cp /usr/bin/scp .
cp /usr/bin/rssh .
cp /usr/bin/sftp .
cd $BASEDIR/usr/libexec/openssh/
cp /usr/libexec/openssh/sftp-server .

# cp /usr/lib/openssh/sftp-server .
cd $BASEDIR/usr/libexec/
cp /usr/libexec/rssh_chroot_helper .
#chgrp rsshusers /usr/libexec/rssh_chroot_helper
#chmod 4750 /usr/libexec/rssh_chroot_helper

# cp /usr/lib/rssh/rssh_chroot_helper
cd $BASEDIR/bin/
#cp /bin/sh .
cp /bin/bash .

#copy binary rsync
cp  -v /bin/rsync $BASEDIR/usr/bin/

# Now copy all shared library files
cd $BASEDIR/bin/
wget -O l2chroot http://www.cyberciti.biz/files/lighttpd/l2chroot.txt
chmod +x l2chroot

sed -i 's|BASE="/webroot"|BASE="$BASEDIR"|g' l2chroot



#./l2chroot /usr/bin/scp
./l2chroot /usr/bin/rssh
./l2chroot /usr/bin/sftp
./l2chroot /bin/rsync
./l2chroot /usr/libexec/openssh/sftp-server

# /tmp/l2chroot /usr/lib/openssh/sftp-server
./l2chroot /usr/libexec/rssh_chroot_helper

# /tmp/l2chroot /usr/lib/rssh/rssh_chroot_helper
#/tmp/l2chroot /bin/sh

#./l2chroot /bin/bash

# Add the NSS modules
cd $BASEDIR/lib64
cp /lib64/*nss* .

# rssh conf
#cat /etc/rssh.conf | sed '/#allowrsync/s/#//' | sed '/#allowsftp/s/#//' > /tmp/rssh.conf.tmp
cp  /etc/rssh.conf /etc/rssh.conf.back

sed -i 's/#allowrsync/allowrsync/g' /etc/rssh.conf
sed -i 's/#allowsftp/allowsftp/g' /etc/rssh.conf
#echo 'chrootpath = $BASEDIR' >>  /etc/rssh.conf

#sed -i 's/#chrootpath = "/usr/local/my chroot"/chrootpath = $BASEDIR/g' /etc/rssh.conf
sed -i 's|#chrootpath = "/usr/local/my chroot"|chrootpath = $BASEDIR|g' /etc/rssh.conf


#echo 'user = $:027:00011:$BASEDIR' >> /etc/rssh.conf
#chmod 644 /etc/rssh.conf


# Add chroot user
#useradd -m -d $BASEDIR/$TESTUSER -s /usr/bin/rssh $TESTUSER
useradd -m -d $BASEDIR/$TESTUSER -s /bin/bash $TESTUSER

# NOTE: set password for testuser
usermod -a -G rsshusers $TESTUSER

# NOTE: Open /users/etc/group and /users/etc/passwd file and remove root and all other accounts.
grep $TESTUSER /etc/group > $BASEDIR/etc/group
grep $TESTUSER /etc/passwd > $BASEDIR/etc/passwd

# end
echo ""
echo ""
echo FIN SCRIPT CHROOT 
echo USER_CHROOT: $TESTUSER 
echo DIR_CHROOT: $BASEDIR


#We make pair key for acces without password
su - $TESTUSER -c "ssh-keygen  -b 4096 -t rsa"
cp  $BASEDIR/$TESTUSER/.ssh/id_rsa.pub  $BASEDIR/$TESTUSER/.ssh/authorized_keys

#Entregar llave al cliente
cp $BASEDIR/$TESTUSER/.ssh/id_rsa $BASEDIR/$TESTUSER/$TESTUSER.ppk

#modify /etc/ssh/sshd_config
echo "" >> /etc/ssh/sshd_config
echo #define username to apply chroot jail to >> /etc/ssh/sshd_config
echo Match User $TESTUSER >> /etc/ssh/sshd_config
echo #specify chroot jail >> /etc/ssh/sshd_config
echo "	ChrootDirectory $BASEDIR" >> /etc/ssh/sshd_config

systemctl restart sshd

#rsync -avz -e "ssh -i $TESTUSER.ppk " file_to_upload_test $TESTUSER@10.x.x.x:/

#####
#Credits to https://gist.github.com/andypowe11 in https://gist.github.com/andypowe11/9c6a7b5b5807c88f9d95c1cde7d97ff5
