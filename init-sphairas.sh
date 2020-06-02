#!/bin/bash

set -e

#Prefix für die Subdomain
PREFIX=listen
UPSTREAM_HOST=${HOSTNAME}
UPSTREAM_PORT=10080
#Apache2 Virtual Host
SITE=999-sphairas-vhost

#Docker Compose
#install Docker Compose if not installed
#https://docs.docker.com/compose/install/
DOCKER_COMPOSE_BINARY=/usr/local/bin/docker-compose
if [ ! -f ${DOCKER_COMPOSE_BINARY} ]; then 
    read -p "Docker Compose ist nicht installiert. Installieren? (Ja/Nein) " JN
    if [ ${JN} != 'Ja' ]; then exit 0; fi 
    curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o ${DOCKER_COMPOSE_BINARY}
    chmod +x ${DOCKER_COMPOSE_BINARY}
    echo "Docker Compose installiert in ${DOCKER_COMPOSE_BINARY}."
fi

SPHAIRAS_HOSTNAME=${HOSTNAME}
echo "Wird die Client-Anwendung für die Administration den Server unter ${HOSTNAME}:4848 und ${HOSTNAME}:7781 erreichen?"
read -p "Sie können einen anderen Hostnamen angeben oder diesen Schritt überspringen:" ALT_HOST
if [ x${ALT_HOST} != x ]; then
    SPHAIRAS_HOSTNAME=${ALT_HOST}
fi

#generate random passwords for mysql
MYSQL_ROOT_PASSWORD_GENERATED=`openssl rand -base64 16`
MYSQL_DB_PASSWORD_GENERATED=`openssl rand -base64 16`

#Verzeichnis für Docker Compose einrichten
SPHAIRAS_INSTALL=/etc/sphairas
echo "Es wird eine Konfigurationsdatei für Docker Compose ${SPHAIRAS_INSTALL}/docker-compose.yml angelegt. Es werden Datei mit Umgebungsvariablen für Docker Compose ${SPHAIRAS_INSTALL}/docker.env und ${SPHAIRAS_INSTALL}/.env angelegt." 

mkdir ${SPHAIRAS_INSTALL}

cat > ${SPHAIRAS_INSTALL}/docker-compose.yml <<EOF
version: '3.3'
services:
  app:
    image: "sphairas/server:latest"
    ports:
      - "8080:8080"
      - "7781:7781"
      - "8181:8181"
    volumes:
      - "app-resources:/app-resources/"
      - "secrets:/run/secrets/"
    depends_on:
      - db
    environment:
      - "DB_HOST=db"
      - "DB_PORT=3306"
      - "DB_NAME=sphairas"
      - "DB_USER=sphairas"
      - "DB_PASSWORD=${DB_PASSWORD}"
    env_file:
      - "docker.env"
  db:
    image: "mysql:5.7.30"
    volumes:
      - "mysql-data:/var/lib/mysql"
    environment:
      - "MYSQL_DATABASE=sphairas"
      - "MYSQL_USER=sphairas"
volumes:
  app-resources:
  secrets:
  mysql-data:
EOF

cat > ${SPHAIRAS_INSTALL}/docker.env <<EOF
#Example docker environment file
#Copy this to "docker.env" and adjust values.

#Unique name of the provider:
#This is the name which clients use to 
#identify different providers/server instances.
#It also identifies several configurable provider services.
#Choose a unique domain name-like name for every provider. 
SPHAIRAS_PROVIDER=${HOSTNAME}

#A domain name-like name used as user suffix for login:
#Its value depends on the login method and the provider.
#In many cases, this will the host name. 
LOGINDOMAIN=${HOSTNAME}

#Either file or iserv are supported
WEB_MODULE_AUTHENTICATION=iserv

#Hostname used for the admin certificate: 
#This should correspond to an external name of the machine
#on which the server is running. The application must
#be reachable by this name from the admin client applications.
SPHAIRAS_HOSTNAME=${SPHAIRAS_HOSTNAME}

#MySql user password:
DB_PASSWORD=${MYSQL_DB_PASSWORD_GENERATED}

#IServ-Authentication
ISERV_IMAP_HOST=${HOSTNAME}
ISERV_IMAP_PORT=993
EOF

cat > ${SPHAIRAS_INSTALL}/.env <<EOF
#Example docker environment file
#Copy this to ".env" and adjust values.
#This .env file may be deleted after the creation
#of the mysql container

#mysql root password set at first startup 
#of the mysql container
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD_GENERATED}

#mysql user password corresponding to the same
#variable in docker.env
DB_PASSWORD=${MYSQL_DB_PASSWORD_GENERATED}
EOF

#Apache2 Virtual Host für die Subdomäne einrichten
echo "Es wird ein virtueller Host ${PREFIX}.${HOSTNAME} in Apache 2 eingerichtet und gestartet."

cat > /etc/apache2/sites-available/${SITE}.conf <<EOF
SSLStrictSNIVHostCheck on

<VirtualHost *:443>

    ServerName ${PREFIX}.${HOSTNAME}

    SSLEngine On
    SSLCertificateFile /etc/letsencrypt/live/iserv/cert.pem 	
    SSLCertificateKeyFile /etc/letsencrypt/live/iserv/privkey.pem 	
    SSLCertificateChainFile /etc/letsencrypt/live/iserv/chain.pem 

    RedirectPermanent / /web/

    ProxyPass /web http://${UPSTREAM_HOST}:${UPSTREAM_PORT}/web connectiontimeout=5 timeout=600 KeepAlive=On
    ProxyPassReverse /web http://${UPSTREAM_HOST}:${UPSTREAM_PORT}/web

    ProxyPass /calendar http://${UPSTREAM_HOST}:${UPSTREAM_PORT}/calendar connectiontimeout=5 timeout=600 KeepAlive=On
    ProxyPassReverse /calendar http://${UPSTREAM_HOST}:${UPSTREAM_PORT}/calendar

    ProxyPass /service http://${UPSTREAM_HOST}:${UPSTREAM_PORT}/service connectiontimeout=5 timeout=600 KeepAlive=On
    ProxyPassReverse /service http://${UPSTREAM_HOST}:${UPSTREAM_PORT}/service

    <Proxy *>
     		Allow from all
    </Proxy>

</VirtualHost>

<VirtualHost *:80>

   ServerName ${PREFIX}.${HOSTNAME}

   Redirect permanent / https://${PREFIX}.${HOSTNAME}

</VirtualHost>
EOF

echo "Der virtuelle Host ${PREFIX}.${HOSTNAME} wird in die Liste der Hostnamen für das Letsencryt-Zertifikat eingetragen."
echo "${PREFIX}.${HOSTNAME}" >> /etc/iserv/ssl-domains
iconf save /etc/iserv/ssl-domains
chkcert -l

echo "Apache 2 wird neu gestartet."
a2ensite ${SITE}
service apache2 reload

echo "Fertig. Wechseln Sie in das Verzeichnis ${SPHAIRAS_INSTALL} und starten Sie die Anwendung mit \"docker-compose up\". Stoppen Sie die Anwendung mit \"docker-compose down\"."
echo "Die Datei \"${SPHAIRAS_INSTALL}/.env\" sollte nach dem ersten erfolgreichen Start wieder gelöscht werden." 

