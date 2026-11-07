FROM ubuntu:22.04 AS curl-build

# curl 8.10.1 is needed for correct --aws-sigv4 handling of signed S3 listing
# requests with a query string. Build it from the official source with a static
# libcurl; the final image is Ubuntu 22.04 (the mongo:7 base), so the binary
# uses the same OpenSSL and zlib.
ARG CURL_VERSION=8.10.1

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      libssl-dev \
      wget \
      zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

RUN wget -q "https://curl.se/download/curl-${CURL_VERSION}.tar.gz" -O /tmp/curl.tar.gz \
 && mkdir -p /tmp/curl \
 && tar -xzf /tmp/curl.tar.gz -C /tmp/curl --strip-components=1 \
 && cd /tmp/curl \
 && ./configure \
      --prefix=/usr/local \
      --disable-shared \
      --enable-static \
      --disable-ldap \
      --disable-ldaps \
      --disable-rtsp \
      --disable-dict \
      --disable-telnet \
      --disable-tftp \
      --disable-pop3 \
      --disable-imap \
      --disable-smtp \
      --disable-gopher \
      --disable-mqtt \
      --without-libpsl \
      --without-libidn2 \
      --without-brotli \
      --without-zstd \
      --without-nghttp2 \
      --without-libssh2 \
      --with-openssl \
      --with-zlib \
 && make -j"$(nproc)" \
 && strip src/curl

FROM mongo:7

# mongo:7 already carries mongosh and mongoimport. openssl is used to produce
# Payload's pbkdf2-sha256-v1 password hash without pulling in a full runtime.
# ca-certificates covers the Atlas mongodb+srv TLS connections. The curl built
# above replaces the base image's 7.81, whose --aws-sigv4 handling breaks signed
# S3 listing requests with a query string.
USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      cron \
      curl \
      jq \
      openssl \
      tzdata \
      util-linux \
 && rm -rf /var/lib/apt/lists/*

COPY --from=curl-build /tmp/curl/src/curl /usr/local/bin/curl
ENV PATH=/usr/local/bin:$PATH

RUN test "$(command -v curl)" = "/usr/local/bin/curl" \
 && curl --version | head -n 1 | grep -q '^curl 8\.10\.1'

COPY sync.sh /usr/local/bin/sync.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY crontab /etc/cron.d/rosso-dev-sync

RUN chmod 755 /usr/local/bin/sync.sh /usr/local/bin/entrypoint.sh \
 && chmod 644 /etc/cron.d/rosso-dev-sync \
 && curl --version

ENV TZ=UTC
VOLUME ["/media"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron", "-f"]
