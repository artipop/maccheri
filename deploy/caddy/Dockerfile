# Caddy with caddy-l4: TURN over TLS shares :443 with HTTPS, routed by SNI.
ARG CADDY_VERSION=2.11
FROM caddy:${CADDY_VERSION}-builder AS build
RUN xcaddy build --with github.com/mholt/caddy-l4

FROM caddy:${CADDY_VERSION}
COPY --from=build /usr/bin/caddy /usr/bin/caddy
