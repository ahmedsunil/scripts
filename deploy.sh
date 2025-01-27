#!/bin/bash

# Deployment Automation Script for PHP/MySQL/Apache Applications
# Author: Ahmed Sunil
# Version: 1.2

set -e # Exit immediately if any command fails

# Logging
exec > >(tee -a deployment.log) 2>&1

# Validate root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo" >&2
    exit 1
fi

# Check for required arguments
if [ $# -ne 5 ]; then
    echo "Usage: $0 <GIT_URL> <APP_NAME> <APP_FOLDER> <DB_NAME> <DB_USER>" >&2
    echo "Example: $0 https://github.com/example/app.git myapp /var/www/myapp mydb myuser" >&2
    exit 1
fi

# Assign variables
GIT_URL=$1
APP_NAME=$2
APP_FOLDER=$3
DB_NAME=$4
DB_USER=$5

# Password prompts
echo -n "Enter database password: "
read -s DB_PASS
echo

echo -n "Enter MySQL root password: "
read -s MYSQL_ROOT_PASS
echo

# System Setup
echo "System Setup..."
apt update -qq && apt upgrade -y -qq
apt install -y -qq software-properties-common

# PHP Installation
echo "Installing PHP 8.3..."
add-apt-repository -y ppa:ondrej/php > /dev/null
apt update -qq
apt install -y -qq php8.3 php8.3-cli php8.3-mysql php8.3-curl \
    php8.3-mbstring php8.3-xml php8.3-zip php8.3-gd php8.3-intl \
    php8.3-bcmath php8.3-opcache

# Apache & MySQL
echo "Installing Apache & MySQL..."
apt install -y -qq apache2 mysql-server

# Node.js
echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null
apt install -y -qq nodejs

# Composer
echo "Installing Composer..."
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php composer-setup.php --quiet
rm composer-setup.php
mv composer.phar /usr/local/bin/composer

# Database Setup
echo "Configuring MySQL..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;" > /dev/null

mysql -u root -p"${MYSQL_ROOT_PASS}" <<EOF > /dev/null 2>&1
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Application Deployment
echo "Deploying Application..."
if [ -d "$APP_FOLDER" ]; then
    echo "⚠️  Warning: App folder already exists. Overwriting contents!"
    rm -rf "$APP_FOLDER"
fi

git clone -q "$GIT_URL" "$APP_FOLDER"
cd "$APP_FOLDER"

echo "Installing PHP dependencies..."
composer install --no-interaction --prefer-dist --optimize-autoloader --no-dev

echo "Installing Node.js dependencies..."
npm install --silent

echo "Building assets..."
npm run build --silent

# Create or update .env file
if [ ! -f .env ]; then
    cp .env.example .env
    echo ".env file created."
else
    echo ".env file already exists. No action taken."
fi

# Define key-value pairs to add/update in .env
declare -A ENV_VARS=(
    ["APP_ENV"]="production"
    ["APP_DEBUG"]="false"
    ["DB_HOST"]="localhost"
    ["DB_DATABASE"]="$DB_NAME"
    ["DB_USERNAME"]="$DB_USER"
    ["DB_PASSWORD"]="$DB_PASS"
)

# Loop through the array and update .env
for key in "${!ENV_VARS[@]}"; do
    value="${ENV_VARS[$key]}"
    if grep -q "^$key=" "$APP_FOLDER/.env"; then
        sed -i "s/^$key=.*/$key=$value/" "$APP_FOLDER/.env"
    else
        echo "$key=$value" >> "$APP_FOLDER/.env"
    fi
done

echo "Updated .env file with required values."

# Database Migration
echo "Migrating Database..."
php artisan migrate

echo "Seeding Database..."
php artisan db:seed

# Apache Configuration
echo "🔧 Configuring Apache..."
cat > /etc/apache2/sites-available/"$APP_NAME".conf <<EOF
<VirtualHost *:80>
    ServerName $APP_NAME
    DocumentRoot $APP_FOLDER/public

    <Directory $APP_FOLDER/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$APP_NAME-error.log
    CustomLog \${APACHE_LOG_DIR}/$APP_NAME-access.log combined
</VirtualHost>
EOF

# Enable Configuration
a2enmod rewrite > /dev/null
a2dissite 000-default.conf > /dev/null
a2ensite "$APP_NAME".conf > /dev/null

# Permissions
chown -R www-data:www-data "$APP_FOLDER"
chmod -R 755 "$APP_FOLDER"

# Finalization
echo "Restarting Services..."
systemctl restart apache2 > /dev/null

echo -e "\n✅ Deployment Complete!"
echo "🔗 Visit your application at: http://$(curl -s ifconfig.me)"
echo "⚠️  Remember to:"
echo "   - Configure your .env file (if not already done)"
echo "   - Set up SSL/TLS"
echo "   - Implement proper firewall rules"
