# Backup sidecar: pg_dump + rclone on a cron schedule. Built on the VPS by compose (pull_policy: build), never published.
FROM alpine:3.24

# The client must match the server's major version (17): an older pg_dump refuses a newer server.
RUN apk add --no-cache postgresql17-client rclone tzdata

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["schedule"]
