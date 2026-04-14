FROM node:22-slim AS build
WORKDIR /app
COPY web/package*.json ./
RUN npm ci
COPY web/ ./
RUN npx ember build --environment=production

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY web/public/data /usr/share/nginx/html/data

# SPA fallback + no-cache for dev
RUN printf 'server {\n\
  listen 8092;\n\
  root /usr/share/nginx/html;\n\
  index index.html;\n\
  location / {\n\
    try_files $uri $uri/ /index.html;\n\
  }\n\
  location ~* \\.(js|css|wasm)$ {\n\
    add_header Cache-Control "no-cache";\n\
  }\n\
}\n' > /etc/nginx/conf.d/default.conf

EXPOSE 8092
