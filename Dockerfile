FROM centos:7

LABEL maintainer="pan.luo@ubc.ca"

# https://wiki.shibboleth.net/confluence/display/SP3/LinuxRH6
ENV LD_LIBRARY_PATH=/opt/shibboleth/lib64:$LD_LIBRARY_PATH
# Shibd log level
ENV LOG_LEVEL=INFO
ENV SHIBD_VERSION=3.0.4-3.2

WORKDIR /etc/shibboleth

RUN curl -Ls http://download.opensuse.org/repositories/security://shibboleth/CentOS_7/security:shibboleth.repo  --output /etc/yum.repos.d/security:shibboleth.repo \
    && yum -y update \
    && yum -y install shibboleth-${SHIBD_VERSION} mysql-connector-odbc gettext mysql nc \
    && yum -y clean all

COPY shibboleth2.xml-template /etc/shibboleth/
COPY console.logger-template /etc/shibboleth/
COPY docker-entrypoint.sh /
COPY attribute-map.xml /etc/shibboleth/

EXPOSE 1600

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["shibd", "-F", "-u", "shibd"]
