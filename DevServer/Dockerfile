FROM nginx:alpine

# Copy our static content
COPY public/ /usr/share/nginx/html/

# Use custom nginx config with test endpoints
COPY default.conf /etc/nginx/conf.d/default.conf

# Default Nginx already serves /usr/share/nginx/html on :80
# We'll expose 80 and rely on docker run -p 18080:80
EXPOSE 80
