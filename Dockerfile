FROM centos:7

LABEL maintainer="pan.luo@ubc.ca"

# https://wiki.shibboleth.net/confluence/display/SP3/LinuxRH6
ENV LD_LIBRARY_PATH=/opt/shibboleth/lib64:$LD_LIBRARY_PATH

RUN curl -Ls http://download.opensuse.org/repositories/security://shibboleth/CentOS_7/security:shibboleth.repo  --output /etc/yum.repos.d/security:shibboleth.repo \
    && yum -y update \
    && yum -y install shibboleth-3.0.3-1.1 mysql-connector-odbc gettext mysql nc \
    && yum -y clean all

COPY shibboleth2.xml-template /etc/shibboleth/
COPY docker-entrypoint.sh /

EXPOSE 1600

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["shibd", "-F", "-u", "shibd"]
