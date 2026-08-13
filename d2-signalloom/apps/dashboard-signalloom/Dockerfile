FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
ARG SOURCE_ID
RUN test -n "$SOURCE_ID"
COPY . .
RUN npx vite build

# The build identity, written where scripts/check-deployed-staleness.sh reads it
# back out of the RUNNING container. Produced in this stage and COPYd into the
# final one rather than written there directly, because nginx-unprivileged ends
# on a non-root USER and could not create a file in /etc; COPY runs as root.
#
# GIT_REF is declared HERE, not beside SOURCE_ID above, so that a commit which
# touches nothing in this build context does not invalidate the source COPY and
# force a full vite rebuild. SOURCE_ID is deliberately NOT re-declared: this
# stage's ARG scope already reaches it, and a second declaration of it below the
# source COPY would move the last such line past that COPY and break the
# cache-ordering assertion in d2-signalloom/test/dashboard-supplychain.bats.
# (That assertion greps for the declaration by name, so this comment must avoid
# spelling it out — which is itself a small trap worth knowing about.)
ARG GIT_REF
RUN printf 'workload=dashboard-signalloom\nsource_id=%s\ngit_ref=%s\n' \
      "$SOURCE_ID" "${GIT_REF:-unknown}" > /build-id

FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
COPY --from=build /build-id /etc/osramp-build-id
EXPOSE 8080
