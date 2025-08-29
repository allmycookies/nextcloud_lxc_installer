#!/bin/bash

# ==============================================================================
# Nextcloud Installer & Manager (Intelligent & Interactive)
# für Debian 12 / Ubuntu 22.04 - v3.0 (mit Fehlerbehebungen)
#
# - Behebt alle bekannten Fehler aus der Nextcloud Administrations-Übersicht.
# - Konfiguriert Redis File-Locking, Imagick-SVG, Wartungsfenster etc.
# - Löst das "Server-zu-sich-selbst" Verbindungsproblem in Containern.
# ==============================================================================

set -e # Beendet das Skript sofort, wenn ein Befehl fehlschlägt

# --- Globale Variablen ---
SERVICES=(
    "apache2.service"
    "mariadb.service"
    "redis-server.service"
)
STATE_FILE=".nextcloud_install_state"
NC_PATH="/var/www/nextcloud"

# ==============================================================================
# --- FUNKTIONSDEFINITIONEN ---
# ==============================================================================

# Funktion zur Bereinigung einer bestehenden Installation
cleanup() {
    echo " Beginne mit der Bereinigung der Nextcloud-Installation..."

    # 1. /etc/hosts-Eintrag entfernen
    echo "→ Entferne Host-Eintrag aus /etc/hosts..."
    sed -i "/${NC_URL}/d" /etc/hosts

    # 2. Apache vHost entfernen
    echo "→ Entferne Apache vHost Konfigurationen..."
    a2dissite "${NC_URL}.conf" &>/dev/null || true
    a2dissite "${NC_URL}-le-ssl.conf" &>/dev/null || true
    rm -f "/etc/apache2/sites-available/${NC_URL}.conf"
    rm -f "/etc/apache2/sites-available/${NC_URL}-le-ssl.conf"
    systemctl reload apache2 &>/dev/null || true

    # 3. Datenbank und DB-Benutzer löschen
    echo "→ Lösche MariaDB Datenbank und Benutzer..."
    if ! systemctl is-active --quiet mariadb.service; then
        echo "   MariaDB-Dienst läuft nicht, starte ihn temporär für die Bereinigung..."
        systemctl start mariadb.service
        sleep 2
    fi
    mysql -e "DROP DATABASE IF EXISTS \`${NC_DB_NAME}\`;"
    mysql -e "DROP USER IF EXISTS '${NC_DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    # 4. Dienste stoppen und deaktivieren
    echo "→ Stoppe und deaktiviere alle relevanten Dienste..."
    systemctl stop "${SERVICES[@]}" &>/dev/null || true
    systemctl disable "${SERVICES[@]}" &>/dev/null || true

    # 5. Nextcloud-Dateien und -Verzeichnisse löschen
    echo "→ Lösche Nextcloud-Verzeichnisse..."
    rm -rf "${NC_PATH}"
    rm -rf "/var/nextcloud_data"

    # 6. Cronjob entfernen
    echo "→ Entferne Cronjob..."
    (crontab -u www-data -l | grep -v "${NC_PATH}/cron.php" | crontab -u www-data -) &>/dev/null || true

    # 7. Statusdatei löschen
    rm -f "$STATE_FILE"
    
    echo "✅ Bereinigung abgeschlossen."
}


# Funktion für den Installationsprozess
installation() {
    # 1. System vorbereiten
    echo " Führe System-Updates durch und installiere Basispakete..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y sudo curl wget unzip tar software-properties-common dirmngr apt-transport-https gnupg2 ca-certificates lsb-release
    echo "✅ Systemvorbereitung abgeschlossen."

    # 2. PHP und benötigte Erweiterungen installieren
    echo " Installiere PHP 8.2 und alle benötigten Erweiterungen (inkl. Imagick-SVG)..."
    if ! apt-key list | grep -q "ondrej/php"; then
        curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
        sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
        apt-get update
    fi
    
    apt-get install -y php8.2 libapache2-mod-php8.2
    apt-get install -y \
        php8.2-gd php8.2-mysql php8.2-curl php8.2-mbstring php8.2-intl \
        php8.2-gmp php8.2-bcmath php8.2-xml php8.2-zip php8.2-imagick \
        php8.2-redis php8.2-apcu imagemagick # Ensure full ImageMagick with SVG support is installed
    echo "✅ PHP-Installation abgeschlossen."

    # 3. Webserver, Datenbank und Cache installieren
    echo " Installiere und konfiguriere Apache, MariaDB und Redis..."
    apt-get install -y apache2 mariadb-server redis-server
    systemctl enable --now "${SERVICES[@]}"
    
    mysql -e "CREATE DATABASE \`${NC_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "CREATE USER '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${NC_DB_NAME}\`.* TO '${NC_DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    echo "✅ Datenbank und Caching-Dienst konfiguriert."

    # 4. Nextcloud herunterladen und extrahieren
    echo " Lade Nextcloud v${NC_VERSION} herunter..."
    cd /tmp
    wget -q --show-progress "https://download.nextcloud.com/server/releases/nextcloud-${NC_VERSION}.zip"
    unzip -q "nextcloud-${NC_VERSION}.zip"
    mv nextcloud "${NC_PATH}"
    rm "nextcloud-${NC_VERSION}.zip"
    echo "✅ Nextcloud heruntergeladen und extrahiert."

    # 5. Berechtigungen setzen
    echo " Setze Dateiberechtigungen..."
    mkdir -p /var/nextcloud_data
    chown -R www-data:www-data "${NC_PATH}/"
    chown -R www-data:www-data "/var/nextcloud_data/"
    chmod -R 750 "${NC_PATH}/"
    chmod -R 750 "/var/nextcloud_data/"
    echo "✅ Berechtigungen gesetzt."

    # 6. Apache vHost erstellen
    echo " Erstelle Apache vHost..."
    tee "/etc/apache2/sites-available/${NC_URL}.conf" > /dev/null <<EOF
<VirtualHost *:80>
    ServerAdmin admin@${NC_URL}
    ServerName ${NC_URL}
    DocumentRoot ${NC_PATH}

    <Directory ${NC_PATH}/>
        Require all granted
        # AllowOverride All is required for the Nextcloud .htaccess file to work.
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    # Add security and privacy related headers
    <IfModule mod_headers.c>
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-Permitted-Cross-Domain-Policies "none"
        Header always set X-Robots-Tag "noindex, nofollow"
        Header always set Referrer-Policy "no-referrer"
    </IfModule>

    # Add mime types for modern file formats
    <IfModule mod_mime.c>
      AddType image/svg+xml svg svgz
      AddType application/wasm wasm
      # Serve ESM javascript files (.mjs) with correct mime type
      AddType text/javascript js mjs
    </IfModule>

    # Service discovery and other rewrites
    <IfModule mod_rewrite.c>
        RewriteEngine on
        # These are the essential rewrites for service discovery.
        # The full .htaccess file is still used via "AllowOverride All".
        RewriteRule ^\.well-known/carddav /remote.php/dav/ [R=301,L]
        RewriteRule ^\.well-known/caldav /remote.php/dav/ [R=301,L]
        RewriteRule ^ocm-provider/?$ /index.php [QSA,L]
        RewriteRule ^ocs-provider/?$ /index.php [QSA,L]
        RewriteRule ^\.well-known/(?!acme-challenge|pki-validation) /index.php [QSA,L]
    </IfModule>

</VirtualHost>
EOF
    a2ensite "${NC_URL}.conf"
    a2enmod rewrite headers env dir mime
    systemctl restart apache2
    echo "✅ Apache konfiguriert."

    # 7. PHP-Einstellungen optimieren
    echo " Optimiere PHP-Einstellungen..."
    PHP_INI_FILE=$(find /etc/php -name "php.ini" -and -path "*apache2*")
    sed -i "s/memory_limit = .*/memory_limit = 512M/" "$PHP_INI_FILE"
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = 10G/" "$PHP_INI_FILE"
    sed -i "s/post_max_size = .*/post_max_size = 10G/" "$PHP_INI_FILE"
    sed -i "s/;date.timezone =/date.timezone = Europe\/Berlin/" "$PHP_INI_FILE"
    systemctl restart apache2
    echo "✅ PHP optimiert."

    # 8. Nextcloud Installation via 'occ'
    echo " Führe die Nextcloud Kommandozeilen-Installation aus..."
    sudo -u www-data php "${NC_PATH}/occ" maintenance:install \
        --database "mysql" --database-name "${NC_DB_NAME}" --database-user "${NC_DB_USER}" \
        --database-pass "${NC_DB_PASS}" --admin-user "${NC_ADMIN_USER}" --admin-pass "${NC_ADMIN_PASS}" \
        --data-dir "/var/nextcloud_data"
    echo "✅ Nextcloud-Kerninstallation abgeschlossen."
    
    # 9. NEU: Server-zu-sich-selbst-Problem beheben (Fix für Container-Umgebungen)
    echo " Trage '${NC_URL}' in /etc/hosts ein, um Konnektivitätsprobleme zu beheben..."
    echo "127.0.0.1 ${NC_URL}" >> /etc/hosts
    echo "✅ Host-Eintrag für interne Erreichbarkeit gesetzt."

    # 10. Post-Installation & Fehlerbehebungen via 'occ'
    echo " Führe Post-Installations-Konfigurationen durch..."
    sudo -u www-data php "${NC_PATH}/occ" config:system:set trusted_domains 1 --value="${NC_URL}"
    # Caching
    sudo -u www-data php "${NC_PATH}/occ" config:system:set memcache.local --value '\OC\Memcache\APCu'
    sudo -u www-data php "${NC_PATH}/occ" config:system:set memcache.distributed --value '\OC\Memcache\Redis'
    # Redis Konfiguration
    sudo -u www-data php "${NC_PATH}/occ" config:system:set redis host --value 'localhost'
    sudo -u www-data php "${NC_PATH}/occ" config:system:set redis port --value '6379'
    # Redis für File Locking verwenden
    sudo -u www-data php "${NC_PATH}/occ" config:system:set 'filelocking.enabled' --value='true' --type=boolean
    sudo -u www-data php "${NC_PATH}/occ" config:system:set 'memcache.locking' --value='\OC\Memcache\Redis'
    # Standard-Telefonregion setzen
    sudo -u www-data php "${NC_PATH}/occ" config:system:set default_phone_region --value="DE"
    # Wartungsfenster setzen (auf 1 Uhr nachts)
    sudo -u www-data php "${NC_PATH}/occ" config:system:set maintenance_window_start --type=integer --value="1"
    
    # Reverse-Proxy-Konfiguration
    if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
        echo " Konfiguriere Nextcloud für den Betrieb hinter einem Reverse Proxy..."
        sudo -u www-data php "${NC_PATH}/occ" config:system:set overwrite.cli.url --value="https://${NC_URL}"
        sudo -u www-data php "${NC_PATH}/occ" config:system:set trusted_proxies 0 --value="${REVERSE_PROXY_IP}"
        sudo -u www-data php "${NC_PATH}/occ" config:system:set overwriteprotocol --value="https"
    fi
    echo "✅ Grundkonfiguration abgeschlossen."

    # 11. Cronjob einrichten
    echo " Richte Cronjob ein..."
    (crontab -u www-data -l 2>/dev/null; echo "*/5  * * * * php -f ${NC_PATH}/cron.php") | crontab -u www-data -
    sudo -u www-data php "${NC_PATH}/occ" background:cron
    echo "✅ Cronjob eingerichtet."
    
    # 12. NEU: Teure Reparaturaufgaben ausführen (MIME-Types etc.)
    echo " Führe abschließende Wartungsaufgaben aus (dies kann einen Moment dauern)..."
    sudo -u www-data php "${NC_PATH}/occ" maintenance:repair --include-expensive
    echo "✅ Wartungsaufgaben abgeschlossen."

    # 13. SSL, aber nur wenn KEIN Reverse Proxy verwendet wird
    if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
        echo "ℹ️ Reverse Proxy wird verwendet. SSL/TLS muss auf dem Proxy konfiguriert werden."
        FINAL_URL="https://${NC_URL}"
    else
        read -p "Möchten Sie ein kostenloses SSL-Zertifikat mit Let's Encrypt einrichten? (ja/nein): " setup_ssl
        if [[ "$setup_ssl" == "ja" ]]; then
            apt-get install -y certbot python3-certbot-apache
            certbot --apache --non-interactive --agree-tos --redirect -d "${NC_URL}" -m "admin@${NC_URL}"
            FINAL_URL="https://${NC_URL}"
        else
            FINAL_URL="http://${NC_URL}"
        fi
    fi

    # --- Abschluss ---
    echo -e "\n\n🎉 Die Installation von Nextcloud war erfolgreich! 🎉"
    echo "------------------------------------------------------------------"
    echo "Sie können Nextcloud nun unter folgender Adresse erreichen:"
    echo -e "\n    \033[1m${FINAL_URL}\033[0m\n"
    echo "Ihre Anmeldedaten sind:"
    echo -e "  » Benutzername: \033[1m${NC_ADMIN_USER}\033[0m"
    echo -e "  » Passwort:     \033[1m${NC_ADMIN_PASS}\033[0m"
    echo -e "\nNach der Installation sollte Ihre Administrations-Übersicht keine Fehler mehr anzeigen."
    echo "Denken Sie daran, Ihre E-Mail-Server-Einstellungen manuell in den Nextcloud-Einstellungen zu konfigurieren."
    echo "------------------------------------------------------------------"
}

# Funktion zum Zurücksetzen des Admin-Passworts
reset_password() {
    echo "Setze ein neues Passwort für den Admin-Benutzer '${NC_ADMIN_USER}'."
    read -s -p "Bitte geben Sie das neue Passwort ein: " NEW_PASSWORD
    echo; read -s -p "Bitte bestätigen Sie das neue Passwort: " CONFIRM_PASSWORD; echo

    if [ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]; then echo "❌ Die Passwörter stimmen nicht überein. Abbruch."; exit 1; fi
    if [ -z "$NEW_PASSWORD" ]; then echo "❌ Das Passwort darf nicht leer sein. Abbruch."; exit 1; fi
    sudo -u www-data php "${NC_PATH}/occ" user:resetpassword "${NC_ADMIN_USER}" --password-from-env <<< "OC_PASS=${NEW_PASSWORD}"
    echo "✅ Passwort für '${NC_ADMIN_USER}' wurde erfolgreich zurückgesetzt."
}

# --- Service-Verwaltungsfunktionen ---
check_status() { echo "Status der Nextcloud-Dienste:"; systemctl status "${SERVICES[@]}"; }
start_services() { echo "Starte Nextcloud-Dienste..."; systemctl start "${SERVICES[@]}"; echo "✅ Dienste gestartet."; }
stop_services() { echo "Stoppe Nextcloud-Dienste..."; systemctl stop "${SERVICES[@]}"; echo "✅ Dienste gestoppt."; }
restart_services() { echo "Starte Nextcloud-Dienste neu..."; systemctl restart "${SERVICES[@]}"; echo "✅ Dienste neugestartet."; }


# ==============================================================================
# --- HAUPTLOGIK ---
# ==============================================================================
# (Der Hauptteil des Skripts mit der Menüauswahl bleibt unverändert)
# ... (Hier folgt der unveränderte "HAUPTLOGIK"-Teil aus der vorherigen Antwort)
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
   echo "Dieses Skript muss als root ausgeführt werden." >&2
   exit 1
fi

if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    
    echo
    echo "================ NEXTCLOUD MANAGER ================"
    if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
        echo "Installation (hinter Reverse Proxy: ${REVERSE_PROXY_IP}) für URL '${NC_URL}' (Version: ${NC_VERSION})"
    else
        echo "Installation für URL '${NC_URL}' (Version: ${NC_VERSION})"
    fi
    echo
    echo "Was möchten Sie tun?"
    echo "--- Diensteverwaltung ---"
    echo "  1) Dienstestatus prüfen"
    echo "  2) Dienste starten"
    echo "  3) Dienste stoppen"
    echo "  4) Dienste neustarten"
    echo "--- Installation & Wartung ---"
    echo "  5) Admin-Passwort zurücksetzen ('${NC_ADMIN_USER}')"
    echo "  6) Neuinstallieren (LÖSCHT AKTUELLE INSTALLATION)"
    echo "  7) Vollständig deinstallieren (LÖSCHT ALLES)"
    echo "  8) Abbrechen"
    read -p "Bitte wählen Sie eine Option [1-8]: " choice
    
    case "$choice" in
        1) check_status ;;
        2) start_services ;;
        3) stop_services ;;
        4) restart_services ;;
        5) reset_password ;;
        6)
            read -p "WARNUNG: Dies löscht die aktuelle Nextcloud-Installation vollständig. Sind Sie sicher? (ja/nein): " confirm
            if [[ "$confirm" == "ja" ]]; then
                cleanup
                echo "System wurde bereinigt. Bitte führen Sie das Skript erneut aus, um eine Neuinstallation zu starten."
            else echo "Abbruch."; fi
            ;;
        7)
            read -p "WARNUNG: Dies löscht ALLE Nextcloud-Daten endgültig. Sind Sie sicher? (ja/nein): " confirm
            if [[ "$confirm" == "ja" ]]; then
                cleanup
                echo "Nextcloud wurde vollständig entfernt."
            else echo "Abbruch."; fi
            ;;
        8) echo "Abbruch."; exit 0 ;;
        *) echo "Ungültige Auswahl. Abbruch."; exit 1 ;;
    esac
else
    # Erstinstallation
    echo "Willkommen zum Nextcloud-Installer."
    echo ""

    read -p "Nextcloud-Version, die installiert werden soll [29.0.4]: " NC_VERSION_INPUT
    NC_VERSION=${NC_VERSION_INPUT:-29.0.4}

    read -p "URL für Nextcloud (z.B. cloud.meinefirma.de): " NC_URL
    if [ -z "$NC_URL" ]; then echo "❌ Die URL darf nicht leer sein."; exit 1; fi

    read -p "Benutzername für den Nextcloud-Admin [admin]: " NC_ADMIN_USER_INPUT
    NC_ADMIN_USER=${NC_ADMIN_USER_INPUT:-admin}

    read -s -p "Passwort für den Nextcloud-Admin [Zufällig generiert]: " NC_ADMIN_PASS
    if [ -z "$NC_ADMIN_PASS" ]; then
        NC_ADMIN_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        echo -e "\nEin zufälliges Passwort wurde generiert: \033[1m${NC_ADMIN_PASS}\033[0m"
    else echo; fi

    read -p "Name der MariaDB-Datenbank [nextcloud_db]: " NC_DB_NAME_INPUT
    NC_DB_NAME=${NC_DB_NAME_INPUT:-nextcloud_db}

    read -p "Benutzer für die MariaDB-Datenbank [nextcloud_user]: " NC_DB_USER_INPUT
    NC_DB_USER=${NC_DB_USER_INPUT:-nextcloud_user}
    
    read -s -p "Passwort für den MariaDB-Benutzer [Zufällig generiert]: " NC_DB_PASS
    if [ -z "$NC_DB_PASS" ]; then
        NC_DB_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        echo -e "\nEin zufälliges Passwort wurde generiert."
    else echo; fi

    # NEU: Abfrage für Reverse Proxy
    read -p "Betreiben Sie Nextcloud hinter einem Reverse Proxy? (ja/nein) [nein]: " USE_REVERSE_PROXY
    USE_REVERSE_PROXY=${USE_REVERSE_PROXY:-nein}

    if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
        read -p "Bitte geben Sie die IP-Adresse Ihres Reverse Proxy an: " REVERSE_PROXY_IP
        if [ -z "$REVERSE_PROXY_IP" ]; then
            echo "❌ Die IP-Adresse des Reverse Proxy darf nicht leer sein. Abbruch."
            exit 1
        fi
    fi

    # Variablen in die Statusdatei speichern
    {
        echo "NC_URL='${NC_URL}'"
        echo "NC_VERSION='${NC_VERSION}'"
        echo "NC_ADMIN_USER='${NC_ADMIN_USER}'"
        echo "NC_DB_NAME='${NC_DB_NAME}'"
        echo "NC_DB_USER='${NC_DB_USER}'"
        echo "USE_REVERSE_PROXY='${USE_REVERSE_PROXY}'"
        if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
            echo "REVERSE_PROXY_IP='${REVERSE_PROXY_IP}'"
        fi
    } > "$STATE_FILE"
    
    echo ""
    echo "Konfiguration abgeschlossen. Die Installation wird mit folgenden Werten gestartet:"
    echo "--------------------------------------------------"
    echo "Version:         ${NC_VERSION}"
    echo "URL:             ${NC_URL}"
    echo "Admin-Benutzer:  ${NC_ADMIN_USER}"
    if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
        echo "Reverse Proxy:   Ja (IP: ${REVERSE_PROXY_IP})"
    else
        echo "Reverse Proxy:   Nein"
    fi
    echo "--------------------------------------------------"
    read -p "Drücken Sie Enter, um fortzufahren, oder Strg+C zum Abbrechen."

    installation
fi
