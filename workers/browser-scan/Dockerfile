# CavScope browser engine worker. Chromium lives in the base image; the Playwright version here must
# match the playwright-core version in package.json (1.56.1), or the browser build will not be found.
FROM mcr.microsoft.com/playwright:v1.56.1-noble
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY worker.mjs cli.mjs ./
COPY lib ./lib
ENV NODE_ENV=production
USER pwuser
CMD ["node", "worker.mjs"]
