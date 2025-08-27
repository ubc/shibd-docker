#!/bin/bash
set -e

if [ -z $SHIBD_ATTRIBUTE_MAP_URL ]; then
    ATTRIBUTE_EXTRACTOR='<AttributeExtractor type="XML" validate="true" reloadChanges="false" path="attribute-map.xml"/>'
else
    ATTRIBUTE_EXTRACTOR="<AttributeExtractor type=\"XML\" validate=\"true\" reloadChanges=\"false\" url=\"${SHIBD_ATTRIBUTE_MAP_URL}\" backingFilePath=\"attribute-map.xml\"/>"
fi
envsubst < /etc/shibboleth/shibboleth2.xml-template > /etc/shibboleth/shibboleth2.xml
envsubst < /etc/shibboleth/console.logger-template > /etc/shibboleth/console.logger
sed -i "s|##ATTRIBUTE_EXTRACTOR##|$ATTRIBUTE_EXTRACTOR|" /etc/shibboleth/shibboleth2.xml
chmod 644 /etc/shibboleth/shibboleth2.xml
mkdir -p /etc/shibboleth/cert
# gracefully run the command as it will fail when the cert directory is mounted
chown shibd:shibd /etc/shibboleth/cert || true

# generate sp key and cert if they don't exists
if [ ! -f /etc/shibboleth/cert/sp-key.pem ]; then
  if [ -n "$SHIB_SP_CERT" ] && [ -n "$SHIB_SP_KEY" ]; then
      echo -e $SHIB_SP_CERT > /etc/shibboleth/cert/sp-cert.pem
      echo -e $SHIB_SP_KEY > /etc/shibboleth/cert/sp-key.pem
      chown -R shibd:shibd /etc/shibboleth/cert
  else
    echo "Generating new sp key and cert..."
    /etc/shibboleth/keygen.sh -f -u shibd -h $SHIBBOLETH_SP_ENTITY_ID -y 10 -e $SHIBBOLETH_SP_ENTITY_ID -o /etc/shibboleth/cert
  fi
fi

if [ "$SSH_ENABLED" = true ]; then
  if [ ! -f "/etc/ssh/ssh_host_rsa_key" ]; then
    # generate fresh rsa key
    ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa
  fi
  if [ ! -f "/etc/ssh/ssh_host_dsa_key" ]; then
    # generate fresh dsa key
    ssh-keygen -f /etc/ssh/ssh_host_dsa_key -N '' -t dsa
  fi
  if [ ! -f "/etc/ssh/ssh_host_ecdsa_key" ]; then
    ssh-keygen -f /etc/ssh/ssh_host_ecdsa_key -N '' -t dsa
  fi
  if [ ! -f "/etc/ssh/ssh_host_ed25519_key" ]; then
    ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t dsa
  fi

  #prepare run dir
  if [ ! -d "/var/run/sshd" ]; then
    mkdir -p /var/run/sshd
  fi

  if [ -z "$SSH_PUBLIC_KEY"  ]; then
    echo "SSH is enabled. Missing SSH_PUBLIC_KEY env variable! Exiting..."
    exit 1
  fi

  # Create a folder to store user's SSH keys if it does not exist.
  USER_SSH_KEYS_FOLDER=/root/.ssh
  [ ! -d "$USER_SSH_KEYS_FOLDER"  ] && mkdir -p $USER_SSH_KEYS_FOLDER

  # Copy contents from the `SSH_PUBLIC_KEY` environment variable
  # to the `${USER_SSH_KEYS_FOLDER}/authorized_keys` file.
  # The environment variable must be set when the container starts.
  echo $SSH_PUBLIC_KEY > ${USER_SSH_KEYS_FOLDER}/authorized_keys
  chown -R root:root $USER_SSH_KEYS_FOLDER && chmod -R 600 $USER_SSH_KEYS_FOLDER

  # Clear the `SSH_PUBLIC_KEY` environment variable.
  unset SSH_PUBLIC_KEY

  env | grep '_\|PATH' | awk '{print "export " $0}' >> /root/.profile

  /sbin/sshd
fi

exec "$@"
