FROM centos:7

LABEL maintainer="pan.luo@ubc.ca"

# https://wiki.shibboleth.net/confluence/display/SP3/LinuxRH6
ENV LD_LIBRARY_PATH=/opt/shibboleth/lib64:$LD_LIBRARY_PATH

RUN curl -Ls http://download.opensuse.org/repositories/security://shibboleth/CentOS_7/security:shibboleth.repo  --output /etc/yum.repos.d/security:shibboleth.repo \
    && yum -y update \
    && yum -y install shibboleth-3.0.3-1.1 mysql-connector-odbc \
    && yum -y clean all

ADD shibboleth2.xml /etc/shibboleth/

EXPOSE 1600

CMD ["shibd", "-F"]
