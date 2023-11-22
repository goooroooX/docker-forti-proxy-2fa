FROM alpine as builder

ARG OPENFORTIVPN_VERSION=v1.21.0
ARG GLIDER_VERSION=v0.16.3

# Build openfortivpn binary
RUN apk add --no-cache \
        openssl-dev \
        ppp \
        ca-certificates \
        curl \
    && apk add --no-cache --virtual .build-deps \
        automake \
        autoconf \
        g++ \
        gcc \
        make \
        go \
        build-base \
    && mkdir -p "/usr/src/openfortivpn" \
    && cd "/usr/src/openfortivpn" \
    && curl -Ls "https://github.com/adrienverge/openfortivpn/archive/${OPENFORTIVPN_VERSION}.tar.gz" \
        | tar xz --strip-components 1 \
    && aclocal \
    && autoconf \
    && automake --add-missing \
    && ./configure --prefix=/usr --sysconfdir=/etc \
    && make \
    && make install

# Build glider proxy binary
RUN mkdir -p /go/src/github.com/nadoo/glider && \
  curl -sL https://github.com/nadoo/glider/archive/${GLIDER_VERSION}.tar.gz \
    | tar xz -C /go/src/github.com/nadoo/glider --strip-components=1 && \
  cd /go/src/github.com/nadoo/glider && \
  awk '/^\s+_/{if (!/http/ && !/socks5/ && !/mixed/) $0="//"$0} {print}' feature.go > feature.go.tmp && \
  mv feature.go.tmp feature.go && \
  go build -v -ldflags "-s -w"

# Clean build deps
RUN apk del .build-deps

# Build final image
FROM alpine

RUN apk add --no-cache \
        ca-certificates \
        openssl \
        ppp \
        curl \
        su-exec \
        socat \
        dpkg \
        bash\
        wget \
        iptables \
        net-tools \
        iproute2 \
        inotify-tools

COPY --from=builder /usr/bin/openfortivpn /usr/bin/openfortivpn
COPY --from=builder /go/src/github.com/nadoo/glider/glider /usr/bin/glider
COPY ./docker-entrypoint.sh /usr/bin/
COPY ./inotifywait.sh /usr/bin/
COPY ./docker-healcheck.sh /usr/bin/

RUN chmod +x \
    /usr/bin/docker-entrypoint.sh \
    /usr/bin/docker-healcheck.sh \
    /usr/bin/inotifywait.sh 

RUN mkdir /tmp/2fa/
RUN chmod -R 777 /tmp/2fa/

ENTRYPOINT ["docker-entrypoint.sh"]

ENV VPN_ADDR=""
ENV VPN_USER=""
ENV VPN_PASS=""
ENV VPN_2FA_DIR="/tmp/2fa/"
ENV VPN_2FA_FILE="/tmp/2fa/2fa.txt"
ENV ENABLE_IPTABLES_LEGACY=""
ENV ENABLE_PORT_FORWARDING=""
ENV SOCKS_PROXY_PORT="8443"

EXPOSE 8443/tcp

HEALTHCHECK --interval=30s --timeout=5s \
    CMD bash /usr/bin/docker-healcheck.sh || pkill -SIGILL -f 1

