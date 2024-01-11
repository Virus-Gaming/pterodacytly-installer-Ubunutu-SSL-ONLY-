#!/bin/bash

# Ask the user for input
echo "Enter your email (MUST BE VALID!):"
read email

# Ask the user for input
echo "Enter the domain for the site (DO NOT START WITH https):"
read domain

# Generate a random password with 8 characters
password=$(openssl rand -base64 8)

# Output the generated password
echo "Randomly generated password: $password"

# Changing the login message
sudo bash -c "cat <<EOF > /etc/motd
#####################################################################

This is running Pterodactyl Panel with hostname and SSL Configured!

URL: https://$domain

Admin Login Details:

Username: Admin

Master Password: $password

#####################################################################
EOF"

# Install dependencies
echo "Installing dependencies..."
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
curl -fsSL https://packages.redis.io/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash
apt update
apt -y install php8.1 php8.1-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

# Install Composer
echo "Installing Composer..."
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

# Download and setup Pterodactyl Panel
echo "Downloading Panel Files"
sudo mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Database Setup!
echo "Setting Up Database..."
sudo mysql -u root -p"$password" -e "CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$password';
CREATE DATABASE panel;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"


# Environment Setup
echo "Setting up environment..."
cd /var/www/pterodactyl/
cp .env.example .env
echo "Installing Composer..."
COMPOSER_HOME=/tmp/composer curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
cd /var/www/pterodactyl || exit
composer install --no-dev --optimize-autoloader --no-interaction --no-suggest
php artisan key:generate --force

# Environment Configuration
echo "Setting up environment Database..."
cd /var/www/pterodactyl/
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$password"

echo "Setting up environment..."
cd /var/www/pterodactyl/
php artisan p:environment:setup --author="$email" --url="https://$domain" --timezone="UTC" --cache="redis" --session="redis" --queue="redis" --redis-host="127.0.0.1" --redis-pass="" --redis-port="6379" --settings-ui=1 --telemetry=1

# Database Migration
echo "Migrating database..."
php artisan migrate --seed --force
echo "Done"

# Making user
echo "Creating Default Admin..."
cd /var/www/pterodactyl/
php artisan p:user:make --username="root" --name-first="Admin" --name-last="User" --email="$email" --password=$password --admin=1
echo "DONE!"

# Set Permissions
echo "Setting Permissions..."
sudo chown -R www-data:www-data /var/www/pterodactyl/*
echo "Done!"

# Queue Listeners
echo "Setting up queue listeners..."
(sudo crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | sudo crontab -
echo "[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/pteroq.service > /dev/null
sudo systemctl enable --now redis-server
sudo systemctl enable --now pteroq.service

sudo systemctl start redis-server
sudo systemctl start --now pteroq.service

echo "Done"

# Firewall fixes

sudo ufw allow 80
sudo ufw allow 8080
sudo ufw allow 433

systemctl stop nginx


# NGINX Setup with SSL using Certbot
echo "Setting up Webserber..."
sudo apt update
sudo apt install -y certbot
sudo apt install -y python3-certbot-nginx

echo "Getting Certificate..."
sudo certbot certonly --standalone -d $domain -m "$email" --agree-tos --redirect -n

# Remove default NGINX configuration
sudo rm /etc/nginx/sites-enabled/default

# Create a new NGINX configuration file
cat > /etc/nginx/sites-available/pterodactyl.conf  <<EOF
server_tokens off;

server {
    listen 80;
    server_name $domain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;


    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;


    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Enable NGINX configuration and restart NGINX
sudo ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
sudo systemctl restart nginx

sudo systemctl enable nginx

sudo systemctl enable redis

echo "NGINX setup for Pterodactyl Panel with SSL completed!"

echo "Restarting system"

sudo bash -c "cat <<EOF > /home/pterodactyl-info
#####################################################################

This is running Pterodactyl Panel with hostname and SSL Configured!

URL: https://$domain

Admin Login Details:

Username: Admin

Master Password: $password

#####################################################################
EOF"

reboot now
