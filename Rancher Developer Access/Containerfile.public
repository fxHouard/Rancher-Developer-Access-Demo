ARG NODE_TAG=24
FROM node:${NODE_TAG}
WORKDIR /app
COPY package.json ./
RUN npm install --no-package-lock
COPY . .
EXPOSE 3000
CMD ["node", "src/server.js"]
