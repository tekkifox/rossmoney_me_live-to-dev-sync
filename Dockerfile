FROM curlimages/curl:8.10.1 AS curl

FROM mongo:7

# mongo:7 already carries mongosh and mongoimport. openssl is used to produce
# Payload's pbkdf2-sha256-v1 password hash without pulling in a full runtime.
# ca-certificates covers the Atlas mongodb+srv TLS connections. The statically
# linked curl from the curl stage replaces the base image's 7.81, whose
# --aws-sigv4 handling breaks signed S3 listing requests with a query string.
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

COPY --from=curl /usr/bin/curl /usr/local/bin/curl
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
