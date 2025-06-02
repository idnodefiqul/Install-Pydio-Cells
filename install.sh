#!/bin/bash
set -e

# Cek user root
if [[ $EUID -ne 0 ]]; then
  echo "Jalankan sebagai root atau sudo"
  exit 1
fi

echo "==> Update sistem dan install dependencies dasar..."
apt update && apt upgrade -y
apt install -y curl wget tar jq software-properties-common

# Install database server pilihan user
echo "Pilih database yang ingin digunakan:"
echo "1) MariaDB"
echo "2) MySQL"
echo "3) SQLite (tanpa DB server)"
read -rp "Masukkan pilihan (1/2/3): " db_choice

case $db_choice in
  1)
    echo "Menginstall MariaDB..."
    apt install -y mariadb-server
    systemctl enable --now mariadb
    db_type="mysql"
    ;;
  2)
    echo "Menginstall MySQL..."
    apt install -y mysql-server
    systemctl enable --now mysql
    db_type="mysql"
    ;;
  3)
    echo "Menggunakan SQLite (tidak perlu install DB server)"
    db_type="sqlite"
    ;;
  *)
    echo "Pilihan tidak valid"; exit 1
    ;;
esac

# Setup database jika bukan sqlite
if [[ $db_type == "mysql" ]]; then
  echo "Silakan buat database dan user untuk Pydio Cells."
  read -rp "Nama database: " cells_db
  read -rp "User database: " cells_db_user
  read -rsp "Password user database: " cells_db_pass
  echo
  echo "Membuat database dan user..."

  mysql_root_auth="sudo mysql"

  $mysql_root_auth -e "CREATE DATABASE IF NOT EXISTS \`$cells_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  $mysql_root_auth -e "CREATE USER IF NOT EXISTS '$cells_db_user'@'localhost' IDENTIFIED BY '$cells_db_pass';"
  $mysql_root_auth -e "GRANT ALL PRIVILEGES ON \`$cells_db\`.* TO '$cells_db_user'@'localhost';"
  $mysql_root_auth -e "FLUSH PRIVILEGES;"
fi

echo "Mengunduh dan menginstal Pydio Cells..."
wget -q https://download.pydio.com/latest/cells/release/%7Blatest%7D/linux-amd64/pydio-cells-%7Blatest%7D-linux-amd64.zip -O cells-linux-amd64.zip
unzip cells-linux-amd64.zip
sudo mv cells /usr/local/bin/
sudo mv cells-fuse /usr/local/bin/
sudo chmod +x /usr/local/bin/cells-fuse
sudo chmod +x /usr/local/bin/cells
rm cells-linux-amd64.zip

# Konfigurasi Pydio Cells
echo "Menjalankan konfigurasi Pydio Cells..."
sudo cells install
if [[ $? -ne 0 ]]; then
  echo "Konfigurasi Pydio Cells gagal. Pastikan semua parameter telah diisi dengan benar."
  exit 1
fi

# Buat direktori data
mkdir -p /var/lib/cells
mkdir -p /var/log/cells
chown -R cells:cells /var/lib/cells /var/log/cells

# Input domain
read -rp "Masukkan domain yang akan digunakan (contoh: example.com): " domain

# Pilih webserver
echo "Pilih webserver untuk reverse proxy dan HTTPS:"
echo "1) Nginx"
echo "2) Apache2"
read -rp "Masukkan pilihan (1/2): " webserver_choice

if [[ $webserver_choice == "1" ]]; then
  echo "Menginstall dan setup Nginx..."
  apt install -y nginx certbot python3-certbot-nginx
  systemctl enable --now nginx
elif [[ $webserver_choice == "2" ]]; then
  echo "Menginstall dan setup Apache2..."
  apt install -y apache2 certbot python3-certbot-apache
  systemctl enable --now apache2
else
  echo "Pilihan webserver tidak valid."
  exit 1
fi

# Setup systemd service untuk cells (bind ke localhost supaya hanya bisa diakses via reverse proxy)
cat >/etc/systemd/system/cells.service <<EOF
[Unit]
Description=Pydio Cells Service
After=network.target

[Service]
User=cells
Group=cells
ExecStart=/usr/local/bin/cells start --site_bind=127.0.0.1:8080 --site_external=https://$domain
WorkingDirectory=/var/lib/cells
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cells
systemctl start cells

# Tunggu sebentar biar cells start
sleep 5

# Setup reverse proxy dan HTTPS
if [[ $webserver_choice == "1" ]]; then
  # Nginx config
  cat >/etc/nginx/sites-available/pydio <<EOF
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 443 ssl;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/pydio /etc/nginx/sites-enabled/
  nginx -t
  systemctl reload nginx

  echo "Mengaktifkan sertifikat SSL dengan Certbot..."
  certbot --nginx -d "$domain" --non-interactive --agree-tos -m admin@"$domain" --redirect

elif [[ $webserver_choice == "2" ]]; then
  # Apache config
  a2enmod proxy proxy_http proxy_wstunnel ssl rewrite headers

  cat >/etc/apache2/sites-available/pydio.conf <<EOF
<VirtualHost *:80>
    ServerName $domain

    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8080/
    ProxyPassReverse / http://127.0.0.1:8080/

    RewriteEngine on
    RewriteCond %{SERVER_NAME} =$domain
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>

<VirtualHost *:443>
    ServerName $domain

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$domain/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$domain/privkey.pem

    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8080/
    ProxyPassReverse / http://127.0.0.1:8080/

    RequestHeader set X-Forwarded-Proto "https"
    RewriteEngine on
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule /(.*) ws://127.0.0.1:8080/$1 [P,L]
</VirtualHost>
EOF

  a2ensite pydio.conf
  systemctl reload apache2

  echo "Mengaktifkan sertifikat SSL dengan Certbot..."
  certbot --apache -d "$domain" --non-interactive --agree-tos -m admin@"$domain" --redirect

fi

echo "Instalasi dan konfigurasi selesai!"
echo "Akses Pydio Cells melalui: https://$domain"
