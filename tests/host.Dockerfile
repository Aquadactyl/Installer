# Test the real Ubuntu host provisioning path, including signed APT packages.
# This image is only a test fixture; deploy the panel using its production image.
ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}
COPY deploy.sh /tools/deploy.sh
RUN bash /tools/deploy.sh setup-host \
    && php -r 'exit(PHP_VERSION_ID >= 80400 && PHP_VERSION_ID < 80600 ? 0 : 1);' \
    && php-fpm8.5 -t \
    && nginx -t \
    && composer --version \
    && node --version \
    && runuser -u www-data -- node --version \
    && pnpm --version \
    && runuser -u www-data -- pnpm --version \
    && mariadb --version \
    && redis-server --version \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
