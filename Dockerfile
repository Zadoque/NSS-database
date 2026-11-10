FROM postgres:16-alpine
WORKDIR /opt/nss-database
COPY migrations ./migrations
COPY scripts ./scripts
ENTRYPOINT ["/opt/nss-database/scripts/database.sh"]
CMD ["apply"]
