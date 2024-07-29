FROM ubuntu:22.04

WORKDIR /app

RUN DEBIAN_FRONTEND=noninteractive \
    && sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list \
    && dpkg --add-architecture i386 \
    && apt update \
    && apt install -y --no-install-recommends \
        tzdata \
        openssl \
        libc6:i386 \
        libncurses5:i386 \
        zlib1g:i386 \
        libstdc++6:i386; \
    rm -rf /var/lib/apt/lists/*; \
    ln -fs /usr/share/zoneinfo/Asia/Hong_Kong /etc/localtime; \
    dpkg-reconfigure -f noninteractive tzdata

ENV TZ=Asia/Hong_Kong

COPY app /app
COPY df-crypto /usr/local/bin/df-crypto
COPY libdeslash_shm.so /usr/local/lib/libdeslash_shm.so
COPY usr/local/lib /usr/local/lib
COPY usr/local/share/GeoIP /usr/local/share/GeoIP

RUN mkdir /docker-entrypoint-init.d \
    && mkdir /df-data \
    && chmod 1777 /df-data \
# stun
    && ln -sf /tmp/stun-log /app/stun/log \
    && ln -sf /tmp/stun-pid /app/stun/pid \
# monitor
    && ln -sf /tmp/monitor-log /app/monitor/log \
    && ln -sf /tmp/monitor-pid /app/monitor/pid \
# manager
    && ln -sf /tmp/manager-log /app/manager/log \
    && ln -sf /tmp/manager-pid /app/manager/pid \
# relay
    && ln -sf /tmp/relay-log /app/relay/log \
    && ln -sf /tmp/relay-pid /app/relay/pid \
# bridge
    && ln -sf /tmp/bridge-log /app/bridge/log \
    && ln -sf /tmp/bridge-pid /app/bridge/pid \
    && ln -sf /tmp/bridge-cfg /app/bridge/cfg \
# channel
    && ln -sf /tmp/channel-log /app/channel/log \
    && ln -sf /tmp/channel-pid /app/channel/pid \
    && ln -sf /tmp/channel-cfg /app/channel/cfg \
# dbmw_guild
    && ln -sf /tmp/dbmw_guild-log /app/dbmw_guild/log \
    && ln -sf /tmp/dbmw_guild-pid /app/dbmw_guild/pid \
    && ln -sf /tmp/dbmw_guild-cfg /app/dbmw_guild/cfg \
# dbmw_mnt
    && ln -sf /tmp/dbmw_mnt-log /app/dbmw_mnt/log \
    && ln -sf /tmp/dbmw_mnt-pid /app/dbmw_mnt/pid \
    && ln -sf /tmp/dbmw_mnt-cfg /app/dbmw_mnt/cfg \
# dbmw_stat
    && ln -sf /tmp/dbmw_stat-log /app/dbmw_stat/log \
    && ln -sf /tmp/dbmw_stat-pid /app/dbmw_stat/pid \
    && ln -sf /tmp/dbmw_stat-cfg /app/dbmw_stat/cfg \
# auction
    && ln -sf /tmp/auction-log /app/auction/log \
    && ln -sf /tmp/auction-pid /app/auction/pid \
    && ln -sf /tmp/auction-cfg /app/auction/cfg \
# point
    && ln -sf /tmp/point-log /app/point/log \
    && ln -sf /tmp/point-pid /app/point/pid \
    && ln -sf /tmp/point-cfg /app/point/cfg \
# guild
    && ln -sf /tmp/guild-log /app/guild/log \
    && ln -sf /tmp/guild-pid /app/guild/pid \
# statics
    && ln -sf /tmp/statics-log /app/statics/log \
    && ln -sf /tmp/statics-pid /app/statics/pid \
# coserver
    && ln -sf /tmp/coserver-log /app/coserver/log \
    && ln -sf /tmp/coserver-pid /app/coserver/pid \
# community
    && ln -sf /tmp/community-log /app/community/log \
    && ln -sf /tmp/community-pid /app/community/pid \
# game
    && ln -sf /tmp/game-log /app/game/log \
    && ln -sf /tmp/game-pid /app/game/pid \
    && ln -sf /tmp/game-cfg /app/game/cfg \
    && ln -sf /tmp/game-history /app/game/history \
    && ln -sf /df-data/publickey.pem /app/game/publickey.pem \
    && ln -sf /df-data/Script.pvf /app/game/Script.pvf

VOLUME /df-data

COPY docker-entrypoint.sh /usr/local/bin

ENTRYPOINT ["docker-entrypoint.sh"]

CMD ["run siroco11"]