#!/bin/sh

BOOTSTRAP_DIR="/etc/ldap/bootstrap"
PID_FILE="/var/run/slapd/slapd.pid"

set -eu

status () {
  echo "---> ${@}" >&2
}

set -x
: LDAP_DEBUGLEVEL=${LDAP_DEBUGLEVEL}
: LDAP_DOMAIN=${LDAP_DOMAIN}
: LDAP_ORGANIZATION=${LDAP_ORGANIZATION}
: LDAP_ROOTPASS=${LDAP_ROOTPASS}

if [ ! -e /var/lib/ldap/docker_bootstrapped ]; then
  status "configuring slapd for first run"

  cat <<EOF | debconf-set-selections
slapd slapd/internal/generated_adminpw password ${LDAP_ROOTPASS}
slapd slapd/internal/adminpw password ${LDAP_ROOTPASS}
slapd slapd/password2 password ${LDAP_ROOTPASS}
slapd slapd/password1 password ${LDAP_ROOTPASS}
slapd slapd/dump_database_destdir string /var/lib/ldap/backups/slapd-VERSION
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string ${LDAP_ORGANIZATION}
slapd slapd/backend string HDB
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/no_configuration boolean false
slapd slapd/dump_database select when needed
EOF

  dpkg-reconfigure -f noninteractive slapd

  # check if there are any ldif files to process in bootstrap directory
  if [ -d "${BOOTSTRAP_DIR}" ]
  then
     cd ${BOOTSTRAP_DIR}
     # dir exists - process all ldifs in dir
     filelist=$(ls | grep -E "*.ldif$" || echo "")
     if [ ! -z "${filelist}" ]
     then
        # start slapd if not running
        if [ ! -f "${PID_FILE}" ]
        then
           # need to temporarily start slapd in order to bootstrap ldif changes
           /usr/sbin/slapd -h "ldap:/// ldapi:///" -u openldap -g openldap -d $LDAP_DEBUGLEVEL &
           # give it small amount of time to fully start
           sleep 5
        fi
        # get root dn from config database
        LDAP_ROOT_DN=$(ldapsearch -Y EXTERNAL -Q -H ldapi:/// -w config -b cn=config olcRootDN | grep -E "^olcRootDN:" | awk ' { print $2 } ')

        # process the ldif file
        for file in ${filelist}
        do
           if grep -q "cn\=config" ${file}
           then
              # process config changes via socket
              echo "Processing LDIF file (${file}) through ldapi:/// socket..."
              ldapmodify -Y EXTERNAL -Q -H ldapi:/// -f ${file}
           else
              # process other changes via normal service
              ldapmodify -h localhost -p 389 -D $LDAP_ROOT_DN -w $LDAP_ROOTPASS -f ${file}
           fi
        done
        if [ -f "${PID_FILE}" ]
        then
            # stop slapd so normal start up can proceed
            kill -TERM $(cat "${PID_FILE}")
        fi
     fi
   fi
  # create flag file 
  touch /var/lib/ldap/docker_bootstrapped
else
  status "found already-configured slapd"
fi

status "starting slapd"
set -x
exec /usr/sbin/slapd -h "ldap:///" -u openldap -g openldap -d $LDAP_DEBUGLEVEL
