# Stage 1: Build Nginx from source
FROM alpine:latest AS builder

ARG NGINX_VERSION=1.26.1
ARG NGINX_BUILD_DEPS="build-base linux-headers openssl-dev pcre-dev zlib-dev wget"

# Install build dependencies
RUN apk add --no-cache ${NGINX_BUILD_DEPS}

# Download and compile Nginx with the auth_request module
RUN cd /tmp && \
    wget "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" && \
    tar zxf nginx-${NGINX_VERSION}.tar.gz && \
    cd nginx-${NGINX_VERSION} && \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-threads \
        --with-file-aio \
        --with-ipv6 \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --with-stream_ssl_preread_module \
        --with-compat \
        --with-http_auth_request_module \
    && \
    make && \
    mkdir -p /var/cache/nginx && \
    make install

# Stage 2: Final image with Node.js, Supervisor, and compiled Nginx
FROM node:18-alpine

# Install runtime dependencies
# Need libs used by compiled nginx (pcre, zlib, openssl) + supervisor, gettext, curl
RUN apk add --no-cache supervisor gettext curl pcre zlib libssl3

# Create nginx user/group and required directories
RUN addgroup -S nginx && \
    adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx && \
    mkdir -p /var/log/nginx && \
    chown -R nginx:nginx /var/log/nginx && \
    mkdir -p /var/cache/nginx && \
    chown -R nginx:nginx /var/cache/nginx

# Copy compiled Nginx files from builder stage
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx

# Set working directory for the Node.js app
WORKDIR /app

# Copy package.json and package-lock.json
COPY auth-service/package*.json ./

# Install Node.js dependencies
RUN npm install

# Copy the rest of the auth-service application code
COPY auth-service/ .

# Copy the Nginx configuration *template*
# NOTE: We copied /etc/nginx structure from builder, nginx.conf is already there.
# We need to copy our template OVER the default installed one.
COPY nginx/nginx.conf /etc/nginx/nginx.conf.template

# Remove the default Nginx server block if it exists (might not be present, -f is safe)
RUN rm -f /etc/nginx/conf.d/default.conf

# Create directory for Supervisor logs (though we redirect to stdout/stderr now)
RUN mkdir -p /var/log/supervisor

# Copy the Supervisor configuration file
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Environment variables are expected to be passed at runtime (e.g., via --env-file)

# Command to run Supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"] 