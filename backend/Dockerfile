# Cloud Build's trigger points at this file, with backend/ as the build
# context. A Dockerfile rather than buildpacks because the repository root
# holds only a proxy package.json: a buildpack build from the root would
# produce an image that installs nothing and fails to start.sddsd
FROM node:22-slim

ENV NODE_ENV=production

WORKDIR /app

# `tsx` is a runtime dependency here, not a dev one: the server runs TypeScript
# directly, so `--omit=dev` is safe. npm install resolves runtime dependencies
# from package.json during a Render build.
COPY package.json package-lock.json ./
RUN npm install --omit=dev

COPY server.ts tsconfig.json ./
COPY src ./src

# Cloud Run assigns the port and expects the container to honour it, which
# server.ts already does by reading process.env.PORT.
ENV PORT=8080
EXPOSE 8080

# Run as the image's unprivileged user rather than root.
USER node

CMD ["npm", "start"]
