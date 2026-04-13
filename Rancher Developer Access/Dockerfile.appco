FROM dp.apps.rancher.io/containers/nodejs:24-dev
WORKDIR /app
COPY package.json ./
RUN npm install --no-package-lock
COPY . .
EXPOSE 3000
CMD ["node", "src/server.js"]
