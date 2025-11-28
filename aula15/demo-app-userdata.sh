#!/bin/sh
apt -y update
apt -y install apache2
echo "<h1>My Demo APP running on $(hostname)</h1>" > /var/www/html/index.html
systemctl enable apache2
systemctl restart apache2
