#!/bin/bash

echo "Installation von sphairas in IServ."

set -e

#Prefix für die Subdomain
PREFIX=listen

#Apache 2 Virtual Host Datei
SITE=999-sphairas-vhost

#Host und Port für das Webmodule, Upstream für Apache 2 Proxy
UPSTREAM_HOST=localhost
UPSTREAM_PORT=10080

SPHAIRAS_ADMIN_PORT=8181
SPHAIRAS_ADMIN_MQ_PORT=7781

BASE_HOSTNAME=`echo $HOSTNAME | sed -e "s/^\(iserv\.\)//"`

#Docker Compose installieren, falls nicht schon vorhanden
#https://docs.docker.com/compose/install/
DOCKER_COMPOSE_BINARY=/usr/local/bin/docker-compose
if [ ! -f ${DOCKER_COMPOSE_BINARY} ]; then 
    read -p "Docker Compose ist nicht installiert. Installieren? (Ja/Nein) " JN
    if [ ${JN} != 'Ja' ]; then exit 0; fi 
    curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o ${DOCKER_COMPOSE_BINARY}
    chmod +x ${DOCKER_COMPOSE_BINARY}
    echo "Docker Compose installiert in ${DOCKER_COMPOSE_BINARY}."
fi

echo

SPHAIRAS_HOSTNAME=${BASE_HOSTNAME}
echo "Können die Administrations-Clients den IServ unter ${BASE_HOSTNAME} erreichen?"
read -p "Sie können einen anderen Hostnamen angeben oder diesen Schritt überspringen: " ALT_HOST
if [ x${ALT_HOST} != x ]; then
    SPHAIRAS_HOSTNAME=${ALT_HOST}
fi

echo

#generate random password for mysql
#MYSQL_DB_PASSWORD_GENERATED=(`date | md5sum`)
MYSQL_DB_PASSWORD_GENERATED=`pwgen 24 1`

#Verzeichnis für Docker Compose einrichten
SPHAIRAS_INSTALL=/etc/sphairas

echo "Es werden eine Konfigurationsdatei für Docker Compose ${SPHAIRAS_INSTALL}/docker-compose.yml \
und eine Datei mit Umgebungsvariablen ${SPHAIRAS_INSTALL}/docker.env angelegt." 

mkdir -p ${SPHAIRAS_INSTALL}

GATEWAY=172.0.0.1
#Wir müssen ein Gateway für das Docker-Netzwerk definieren. 
#Das geht nur mit der älteren Docker Compose-Version 2.4.
#Grund: Der IMAPS-Client für die Benutzerauthentifizierung kann den IServ-Host (aufgrund der 
#Firewall-Einstellungen?) aus dem Container nicht unter $HOSTNAME erreichen. ($HOSTNAME wird als 
#externe IP aufgelöst und gilt dann als Verbindung nach außen?)
#Alternative zur Nutzung von 2.4: 
#- Firewall-Einstellungen anpassen?
#- Assigned container gateway beim Start-Up auslesen?
#- Docker-Netzwerk separat vor Docker Compose einrichten?
#version: '3.3' does not support extended IPAM configs
cat > ${SPHAIRAS_INSTALL}/docker-compose.yml <<EOF
version: '2.4'
services:
  app:
    image: "sphairas/server:dev"
    networks: 
      - sphairas_default
    ports:
      - "${UPSTREAM_PORT}:8080"
      - "${SPHAIRAS_ADMIN_MQ_PORT}:7781"
      - "${SPHAIRAS_ADMIN_PORT}:8181"
    volumes:
      - "app-resources:/app-resources/"
      - "secrets:/run/secrets/"
    depends_on:
      - db
    environment:
      - "WEB_MODULE_AUTHENTICATION=iserv"
      - "DB_HOST=db"
      - "DB_PORT=3306"
      - "DB_NAME=sphairas"
      - "DB_USER=sphairas"
      - "DB_PASSWORD=${MYSQL_DB_PASSWORD_GENERATED}"
    env_file:
      - "docker.env"
  db:
    image: "mysql:5.7.30"
    networks: 
      - sphairas_default
    volumes:
      - "mysql-data:/var/lib/mysql"
    environment:
      - "MYSQL_RANDOM_ROOT_PASSWORD=yes"
      - "MYSQL_DATABASE=sphairas"
      - "MYSQL_USER=sphairas"
      - "MYSQL_PASSWORD=${MYSQL_DB_PASSWORD_GENERATED}"
volumes:
  app-resources:
  secrets:
  mysql-data:
networks:
  sphairas_default:
    driver: bridge
    ipam:
      config:
        - subnet: 172.0.0.0/24
          ip_range: 172.0.0.0/24
          gateway: ${GATEWAY}

EOF

chmod 0400 ${SPHAIRAS_INSTALL}/docker-compose.yml

cat > ${SPHAIRAS_INSTALL}/docker.env <<EOF
#Example docker environment file
#Copy this to "docker.env" and adjust values.

#Unique name of the provider:
#This is the name which clients use to 
#identify different providers/server instances.
#It also identifies several configurable provider services.
#Choose a unique domain name-like name for every provider. 
SPHAIRAS_PROVIDER=${BASE_HOSTNAME}

#A domain name-like name used as user suffix for login:
#Its value depends on the login method and the provider.
#In many cases, this will the host name. 
LOGINDOMAIN=${BASE_HOSTNAME}

#Hostname used for the admin certificate: 
#This should correspond to an external name of the machine
#on which the server is running. The application must
#be reachable by this name from the admin client applications.
SPHAIRAS_HOSTNAME=${SPHAIRAS_HOSTNAME}

#IServ-Authentication
ISERV_IMAP_HOST=${GATEWAY}
ISERV_IMAP_PORT=993
EOF

chmod 0400 ${SPHAIRAS_INSTALL}/docker.env

echo

#Apache2 Virtual Host für die Subdomäne einrichten
echo "Es wird ein virtueller Host ${PREFIX}.${BASE_HOSTNAME} in Apache 2 eingerichtet und gestartet."

cat > /etc/apache2/sites-available/${SITE}.conf <<EOF
#SNI checks are not required if all all hosts are secured with a single certificate
#SNI checks have been causing errors lately
#SSLStrictSNIVHostCheck on

<VirtualHost *:443>

    ServerName ${PREFIX}.${BASE_HOSTNAME}

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
     		Require all granted
    </Proxy>

</VirtualHost>

<VirtualHost *:80>

   ServerName ${PREFIX}.${BASE_HOSTNAME}

   Redirect permanent / https://${PREFIX}.${BASE_HOSTNAME}

</VirtualHost>
EOF

#enable virtual host
a2ensite ${SITE}

echo

if ! grep -q -E "^${PREFIX}.${BASE_HOSTNAME}$" /etc/iserv/ssl-domains; then
    echo "Der virtuelle Host ${PREFIX}.${BASE_HOSTNAME} wird in die Liste der Hostnamen für das Letsencryt-Zertifikat eingetragen."
    echo "${PREFIX}.${BASE_HOSTNAME}" >> /etc/iserv/ssl-domains
    iconf save /etc/iserv/ssl-domains
    #lädt u. a. Apache 2 neu
    chkcert -l
fi

openLANPorts(){
echo "Es wird ein neuer Eintrag in der Firewall-Konfiguration angelegt."
cat >> /etc/ferm.d/80local.conf <<EOF
###Begin-sphairas Open ports for sphairas admin clients
domain(ip ip6) {

  table filter {

    #Allow incoming connections to TCP Ports ${SPHAIRAS_ADMIN_PORT} and ${SPHAIRAS_ADMIN_MQ_PORT}
    #          This is used to make services running on the IServ server
    #          available to LAN clients.
    chain input_lan {
      # We don't offer IPv6 for LAN clients yet
      @if @eq(\$DOMAIN, ip) {
        proto tcp dport (${SPHAIRAS_ADMIN_PORT} ${SPHAIRAS_ADMIN_MQ_PORT}) ACCEPT;
      }
    }

     #Allow incoming connections to TCP Ports ${SPHAIRAS_ADMIN_PORT} and ${SPHAIRAS_ADMIN_MQ_PORT}   
#    chain input_world {
#        proto tcp dport (${SPHAIRAS_ADMIN_PORT} ${SPHAIRAS_ADMIN_MQ_PORT}) ACCEPT;
#    }

  }
}
###End-sphairas Open ports for sphairas admin clients
EOF
}

read -p "Die Ports ${SPHAIRAS_ADMIN_PORT} und ${SPHAIRAS_ADMIN_MQ_PORT} müssen für lokale Verbindungen geöffnet sein. Firewall anpassen? (Ja/Nein) " JN
    if [ ${JN} == 'Ja' ]; then
        openLANPorts
        iconf save /etc/ferm.d/80local.conf
    fi 
chmod +x ${DOCKER_COMPOSE_BINARY}

echo
echo "Starte iservchk. Bitte die Ausgabe beachten."

set +e
iservchk

echo
echo "Fertig"
echo "Wechseln Sie in das Verzeichnis ${SPHAIRAS_INSTALL} und starten Sie die Anwendung mit \"docker-compose up\". Stoppen Sie die Anwendung mit \"docker-compose down\"." 
