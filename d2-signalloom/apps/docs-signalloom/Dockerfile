FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
ARG SOURCE_ID
RUN test -n "$SOURCE_ID"
COPY . .
RUN npm run build

ARG GIT_REF
RUN printf 'workload=docs-signalloom\nsource_id=%s\ngit_ref=%s\n' \
      "$SOURCE_ID" "${GIT_REF:-unknown}" > /build-id

FROM cgr.dev/chainguard/busybox:latest@sha256:4e7cb67bb8e5c4c7385aa623b75c5ad41afe435e1910466f9b8db5bf939dcb41 AS readback

FROM cgr.dev/chainguard/nginx:latest@sha256:b91cf888522ed0cc1b6bddadfa8320ac2a131a1003b103ae340217a421f12fcc
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build /app/dist /usr/share/nginx/html/docs
COPY --from=build /build-id /etc/osramp-build-id
# The runtime-freshness guard reads the marker through `sh -c cat`.
COPY --from=readback /usr/bin/busybox /bin/busybox
COPY --from=readback /usr/bin/sh /bin/sh
COPY --from=readback /usr/bin/cat /usr/bin/cat
EXPOSE 8080
