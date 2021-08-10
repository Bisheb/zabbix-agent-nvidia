FROM nvidia/cuda:11.4.0-base-ubuntu20.04

STOPSIGNAL SIGTERM

RUN set -eux && \
    ARCH_SUFFIX="$(arch)"; \
    case "$ARCH_SUFFIX" in \
        i686) export ARCH_SUFFIX='i386' ;; \
        x86_64) [ -f /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 ] && export ARCH_SUFFIX='amd64' || export ARCH_SUFFIX='i386' ;; \
        aarch64) export ARCH_SUFFIX='arm64' ;; \
        armv7l) export ARCH_SUFFIX='armhf' ;; \
        ppc64el|ppc64le) export ARCH_SUFFIX='ppc64le' ;; \
        s390x) export ARCH_SUFFIX='s390x' ;; \
        *) echo "Unknown ARCH_SUFFIX=${ARCH_SUFFIX-}"; exit 1 ;; \
    esac; \
    echo "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d && \
    groupadd --system --gid 1995 zabbix && \
    groupadd --system --gid 999 docker && \
    useradd \
            --system --comment "Zabbix monitoring system" \
            -g zabbix -G root,docker \
            --uid 1997 \
            --shell /sbin/nologin \
            --home-dir /var/lib/zabbix/ \
        zabbix && \
    mkdir -p /etc/zabbix && \
    mkdir -p /etc/zabbix/zabbix_agentd.d && \
    mkdir -p /var/lib/zabbix && \
    mkdir -p /var/lib/zabbix/enc && \
    mkdir -p /var/lib/zabbix/modules && \
    apt-get -y update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
            tini \
            tzdata \
            ca-certificates \
            libssl1.1 \
            libcurl4 \
            libldap-2.4 && \
    apt-get -y autoremove && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/* 

ARG MAJOR_VERSION=5.4
ARG ZBX_VERSION=${MAJOR_VERSION}.3
ARG ZBX_SOURCES=https://git.zabbix.com/scm/zbx/zabbix.git

ENV TERM=xterm ZBX_VERSION=${ZBX_VERSION} ZBX_SOURCES=${ZBX_SOURCES}

RUN set -eux && \
    apt-get -y update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
            autoconf \
            automake \
            libpcre3-dev \
            libssl-dev \
            zlib1g-dev \
            make \
            pkg-config \
            git \
            g++ \
            golang && \
    cd /tmp/ && \
    git -c advice.detachedHead=false clone ${ZBX_SOURCES} --branch ${ZBX_VERSION} --depth 1 --single-branch zabbix-${ZBX_VERSION} && \
    cd /tmp/zabbix-${ZBX_VERSION} && \
    zabbix_revision=`git rev-parse --short HEAD` && \
    sed -i "s/{ZABBIX_REVISION}/$zabbix_revision/g" include/version.h && \
    ./bootstrap.sh && \
    export CFLAGS="-fPIC -pie -Wl,-z,relro -Wl,-z,now" && \
    ./configure \
            --datadir=/usr/lib \
            --libdir=/usr/lib/zabbix \
            --prefix=/usr \
            --sysconfdir=/etc/zabbix \
            --prefix=/usr \
            --with-openssl \
            --enable-ipv6 \
            --enable-agent2 \
            --enable-agent \
            --silent && \
    make -j"$(nproc)" -s && \
    cp /tmp/zabbix-${ZBX_VERSION}/src/go/bin/zabbix_agent2 /usr/sbin/zabbix_agent2 && \
    cp /tmp/zabbix-${ZBX_VERSION}/src/zabbix_get/zabbix_get /usr/bin/zabbix_get && \
    cp /tmp/zabbix-${ZBX_VERSION}/src/zabbix_sender/zabbix_sender /usr/bin/zabbix_sender && \
    cp /tmp/zabbix-${ZBX_VERSION}/src/go/conf/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf && \
    strip /usr/sbin/zabbix_agent2 && \
    strip /usr/bin/zabbix_get && \
    strip /usr/bin/zabbix_sender && \
    cd /tmp/ && \
    rm -rf /tmp/zabbix-${ZBX_VERSION}/ && \
    apt-get -y purge \
            autoconf \
            automake \
            libpcre3-dev \
            libssl-dev \
            zlib1g-dev \
            make \
            pkg-config \
            git \
            g++ \
            golang && \ 
    chown --quiet -R zabbix:root /etc/zabbix/ /var/lib/zabbix/ && \
    chgrp -R 0 /etc/zabbix/ /var/lib/zabbix/ && \
    chmod -R g=u /etc/zabbix/ /var/lib/zabbix/ && \
    apt-get -y autoremove && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/*

EXPOSE 10050/TCP

WORKDIR /var/lib/zabbix

COPY ["docker-entrypoint.sh", "/usr/bin/"]

RUN mkdir /etc/zabbix/scripts

COPY ["get_gpus_info.sh", "/etc/zabbix/scripts"]

RUN echo "### Monitoring nvidia-smi \
\nUserParameter=gpu.number,/usr/bin/nvidia-smi -L | /bin/grep GeForce | /usr/bin/wc -l \
\nUserParameter=gpu.discovery,/etc/zabbix/scripts/get_gpus_info.sh \
\nUserParameter=gpu.fanspeed[*],nvidia-smi --query-gpu=fan.speed --format=csv,noheader,nounits \$1 | tr -d \"\\\n\" \
\nUserParameter=gpu.power[*],nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits \$1 | tr -d \"\\\n\" \
\nUserParameter=gpu.temp[*],nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits \$1 | tr -d \"\\\n\" \
\nUserParameter=gpu.utilization[*],nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits \$1 | tr -d \"\\\n\" \
\nUserParameter=gpu.memfree[*],nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits \$1 | tr -d \"\\\n\" \
\nUserParameter=gpu.memused[*],nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits \$1 | tr -d \"\\\n\" \
\nUserParameter=gpu.memtotal[*],nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \$1 | tr -d \"\\\n\"" \
>> /etc/zabbix/zabbix_agent2.conf

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/docker-entrypoint.sh"]

USER 1997

CMD ["/usr/sbin/zabbix_agent2", "--foreground", "-c", "/etc/zabbix/zabbix_agent2.conf"]
