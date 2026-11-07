FROM mongo:7

# mongo:7 already carries mongosh and mongoimport. openssl is used to produce
# Payload's pbkdf2-sha256-v1 password hash without pulling in a full runtime.
# ca-certificates covers the Atlas mongodb+srv TLS connections.
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

COPY sync.sh /usr/local/bin/sync.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY crontab /etc/cron.d/rosso-dev-sync

RUN chmod 755 /usr/local/bin/sync.sh /usr/local/bin/entrypoint.sh \
 && chmod 644 /etc/cron.d/rosso-dev-sync

ENV TZ=UTC
VOLUME ["/media"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron", "-f"]
