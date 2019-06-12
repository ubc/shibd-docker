#!/bin/bash
set -e

envsubst < /etc/shibboleth/shibboleth2.xml-template > /etc/shibboleth/shibboleth2.xml
chmod 644 /etc/shibboleth/shibboleth2.xml

mkdir -p /etc/shibboleth/cert
chown shibd:shibd /etc/shibboleth/cert

# generate sp key and cert if they don't exists
if [ ! -f /etc/shibboleth/cert/sp-key.pem ]; then
  /etc/shibboleth/keygen.sh -f -u shibd -h $SHIBBOLETH_SP_ENTITY_ID -y 10 -e $SHIBBOLETH_SP_ENTITY_ID -o /etc/shibboleth/cert
fi

# Wait for the DB to come up
while [ `/bin/nc -w 1 $SHIBD_ODBC_SERVER $SHIBD_ODBC_PORT < /dev/null > /dev/null; echo $?` != 0 ]; do
    echo "Waiting for database to come up at $SHIBD_ODBC_SERVER:$SHIBD_ODBC_PORT..."
    sleep 1
done

# init necessary tables and data for shibd to work
mysql -u $SHIB_ODBC_USER -p$SHIB_ODBC_PASSWORD -h $SHIBD_ODBC_SERVER -P $SHIBD_ODBC_PORT $SHIBD_ODBC_DATABASE << 'EOF'
CREATE TABLE IF NOT EXISTS version (
    major int NOT NULL,
    minor int NOT NULL,
    UNIQUE(major, minor)
    );
CREATE TABLE IF NOT EXISTS strings (
    context varchar(255) not null,
    id varchar(255) not null,
    expires datetime not null,
    version smallint not null,
    value varchar(255) not null,
    PRIMARY KEY (context, id)
    );
CREATE TABLE IF NOT EXISTS texts (
    context varchar(255) not null,
    id varchar(255) not null,
    expires datetime not null,
    version smallint not null,
    value text not null,
    PRIMARY KEY (context, id)
    );
INSERT IGNORE INTO version VALUES (1,0);
EOF

exec "$@"
