FROM rockylinux:9.3

LABEL maintainer="pan.luo@ubc.ca"

# https://wiki.shibboleth.net/confluence/display/SP3/LinuxRH6
ENV LD_LIBRARY_PATH=/opt/shibboleth/lib64:$LD_LIBRARY_PATH
# Shibd log level
ENV LOG_LEVEL=INFO
ENV SHIBD_VERSION=3.5.0-1.el9
ENV SHIBD_REMOTE_USER=somerandomname
ENV SHIBD_CONSISTENT_ADDRESS=true
ENV SHIBBOLETH_IDP_METADATA_BACKUPFILE=/var/cache/shibboleth/shibboleth-metadata-idp.xml
ENV SHIBBOLETH_SESSION_LIFETIME=7200
ENV SHIBBOLETH_SESSION_TIMEOUT=3600
ENV SHIBBOLETH_CACHE_TIMEOUT=3600

WORKDIR /etc/shibboleth

COPY shibboleth.repo /etc/yum.repos.d/

RUN yum -y update \
    && dnf install -y 'dnf-command(config-manager)' \
    && dnf config-manager --set-enabled crb \
    && yum -y install shibboleth-${SHIBD_VERSION} mariadb-connector-odbc gettext mysql nc \
    && yum -y clean all

COPY shibboleth2.xml-template /etc/shibboleth/
COPY console.logger-template /etc/shibboleth/
COPY docker-entrypoint.sh /
COPY attribute-map.xml /etc/shibboleth/

EXPOSE 1600

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["shibd", "-F", "-u", "shibd"]
