FROM docker.io/library/node:22-alpine
WORKDIR /opt/app
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY app.js cache.js config.js metrics.js server.js setup.js ./
COPY public ./public
COPY sql ./sql
RUN chgrp -R 0 /opt/app && chmod -R g=u /opt/app
USER 1001
ENV HOST=0.0.0.0 PORT=3102
EXPOSE 3102
CMD ["node", "server.js"]
