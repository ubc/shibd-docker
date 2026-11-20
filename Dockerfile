FROM rockylinux:9.3

LABEL maintainer="pan.luo@ubc.ca"

# https://wiki.shibboleth.net/confluence/display/SP3/LinuxRH6
ENV LD_LIBRARY_PATH=/opt/shibboleth/lib64:$LD_LIBRARY_PATH
# Shibd log level
ENV LOG_LEVEL=INFO
ENV SHIBD_VERSION=3.5.0-1.el9
ENV SHIBD_REMOTE_USER=somerandomname
ENV SHIBD_CONSISTENT_ADDRESS=true
ENV SHIBBOLETH_COOKIE_PROPS=http
ENV SHIBBOLETH_IDP_METADATA_BACKUPFILE=/var/cache/shibboleth/shibboleth-metadata-idp.xml
ENV SHIBBOLETH_SESSION_LIFETIME=7200
ENV SHIBBOLETH_SESSION_TIMEOUT=3600
ENV SHIBBOLETH_CACHE_TIMEOUT=3600
# odbc (shared MariaDB/MySQL, the default) or memory (one replica, no database)
ENV SHIBD_STORAGE=odbc
ENV SHIBBOLETH_HANDLER_SSL=false
# memory mode: where a login whose target was lost lands (ApplicationDefaults homeURL)
ENV SHIBBOLETH_HOME_URL=/

WORKDIR /etc/shibboleth

COPY shibboleth.repo /etc/yum.repos.d/

# The RPM's %post generates sp-signing-* and sp-encrypt-* key pairs. The
# configuration uses cert/sp-key.pem and cert/sp-cert.pem instead, and a key
# baked into a public image is no secret, so remove them in the same layer.
# libxml2 has the xmllint check-idp-metadata.sh uses (gettext and dnf pull it in anyway).
RUN yum -y update \
    && dnf install -y 'dnf-command(config-manager)' \
    && dnf config-manager --set-enabled crb \
    && yum -y install shibboleth-${SHIBD_VERSION} mariadb-connector-odbc gettext mysql nc libxml2 \
    && ln -s /usr/lib64/libmaodbc.so /usr/lib64/libmyodbc8.so \
    && rm -f /etc/shibboleth/sp-signing-key.pem /etc/shibboleth/sp-signing-cert.pem \
             /etc/shibboleth/sp-encrypt-key.pem /etc/shibboleth/sp-encrypt-cert.pem \
    && yum -y clean all

COPY shibboleth2.xml-template /etc/shibboleth/
COPY console.logger-template /etc/shibboleth/
COPY docker-entrypoint.sh render-config.sh check-idp-metadata.sh /
COPY attribute-map.xml /etc/shibboleth/

EXPOSE 1600

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["shibd", "-F", "-u", "shibd"]
