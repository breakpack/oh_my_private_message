FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.js ./
ENV HOST=0.0.0.0 PORT=8080
EXPOSE 8080
USER node
CMD ["node", "server.js"]
