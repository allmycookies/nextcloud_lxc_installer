#!/bin/bash

# ==============================================================================
# Nextcloud Installer & Manager (Intelligent & Interactive)
# für Debian 12 / Ubuntu 22.04 - v1.0
#
# - Führt eine interaktive Erstinstallation mit sinnvollen Standardwerten durch.
# - Richtet eine vollständige LAMP-Umgebung, Redis-Cache und optional SSL ein.
# - Erkennt eine bestehende Installation und bietet ein Verwaltungsmenü an.
# - Verwaltet Dienste (Status, Start, Stop, Neustart).
# - Bietet Optionen für Deinstallation, Neuinstallation und Passwort-Reset.
#
# Inspiriert von Denys Safra's Paperless-ngx Installer
# (c) 2025 Ihr KI-Assistent
# ==============================================================================

set -e # Beendet das Skript sofort, wenn ein Befehl fehlschlägt

# --- Globale Variablen ---
# Diese Dienste sind für den Betrieb von Nextcloud relevant
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

    # Dienste stoppen und deaktivieren
    echo "→ Stoppe und deaktiviere Dienste..."
    systemctl stop "${SERVICES[@]}" &>/dev/null || true
    systemctl disable "${SERVICES[@]}" &>/dev/null || true

    # Apache vHost entfernen
    echo "→ Entferne Apache vHost Konfiguration..."
    if [ -f "/etc/apache2/sites-available/${NC_URL}.conf" ]; then
        a2dissite "${NC_URL}.conf" &>/dev/null || true
        rm -f "/etc/apache2/sites-available/${NC_URL}.conf"
        systemctl reload apache2
    fi
     if [ -f "/etc/apache2/sites-available/${NC_URL}-le-ssl.conf" ]; then
        a2dissite "${NC_URL}-le-ssl.conf" &>/dev/null || true
        rm -f "/etc/apache2/sites-available/${NC_URL}-le-ssl.conf"
        systemctl reload apache2
    fi

    # Datenbank und DB-Benutzer löschen
    echo "→ Lösche MariaDB Datenbank und Benutzer..."
    # Prüfen, ob die Datenbank existiert, bevor sie gelöscht wird
    if mysql -e "USE \`${NC_DB_NAME}\`;" &>/dev/null; then
        mysql -e "DROP DATABASE \`${NC_DB_NAME}\`;"
    else
        echo "   Datenbank ${NC_DB_NAME} nicht gefunden, übersprungen."
    fi
    # Prüfen, ob der Benutzer existiert, bevor er gelöscht wird
    if mysql -e "SELECT user FROM mysql.user WHERE user='${NC_DB_USER}'" | grep -q "${NC_DB_USER}"; then
        mysql -e "DROP USER '${NC_DB_USER}'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    else
        echo "   Datenbankbenutzer ${NC_DB_USER} nicht gefunden, übersprungen."
    fi

    # Nextcloud-Dateien löschen
    echo "→ Lösche Nextcloud-Verzeichnis (${NC_PATH})..."
    rm -rf "${NC_PATH}"
    rm -rf "/var/nextcloud_data" # Standard-Datenverzeichnis

    # Cronjob entfernen
    echo "→ Entferne Cronjob..."
    (crontab -u www-data -l | grep -v "${NC_PATH}/cron.php") | crontab -u www-data -

    # Statusdatei löschen
    rm -f "$STATE_FILE"
    echo "✅ Bereinigung abgeschlossen."
}

# Funktion für den Installationsprozess
installation() {
    # 1. System vorbereiten und Basispakete installieren
    echo " Führe System-Updates durch und installiere Basispakete..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y sudo curl wget unzip tar software-properties-common dirmngr apt-transport-https gnupg2 ca-certificates lsb-release
    echo "✅ Systemvorbereitung abgeschlossen."

    # 2. PHP und benötigte Erweiterungen installieren (über PPA für aktuelle Versionen)
    echo " Installiere PHP 8.2 und alle benötigten Erweiterungen..."
    # Füge das PPA von Ondřej Surý hinzu, um aktuelle PHP-Versionen zu erhalten
    if ! apt-key list | grep -q "ondrej/php"; then
        curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
        sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
        apt-get update
    fi
    
    apt-get install -y php8.2 libapache2-mod-php8.2
    apt-get install -y \
        php8.2-gd php8.2-mysql php8.2-curl php8.2-mbstring php8.2-intl \
        php8.2-gmp php8.2-bcmath php8.2-xml php8.2-zip php8.2-imagick \
        php8.2-redis php8.2-apcu
    echo "✅ PHP-Installation abgeschlossen."

    # 3. Apache, MariaDB und Redis installieren und konfigurieren
    echo " Installiere und konfiguriere Apache, MariaDB und Redis..."
    apt-get install -y apache2 mariadb-server redis-server
    systemctl enable --now "${SERVICES[@]}"
    
    # Datenbank und Benutzer erstellen
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
    echo " Setze Dateiberechtigungen für Nextcloud..."
    mkdir -p /var/nextcloud_data
    chown -R www-data:www-data "${NC_PATH}/"
    chown -R www-data:www-data "/var/nextcloud_data/"
    chmod -R 750 "${NC_PATH}/"
    chmod -R 750 "/var/nextcloud_data/"
    echo "✅ Berechtigungen gesetzt."

    # 6. Apache vHost erstellen
    echo " Erstelle Apache vHost-Konfiguration..."
    tee "/etc/apache2/sites-available/${NC_URL}.conf" > /dev/null <<EOF
<VirtualHost *:80>
    ServerAdmin admin@${NC_URL}
    ServerName ${NC_URL}
    DocumentRoot ${NC_PATH}

    <Directory ${NC_PATH}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
    a2ensite "${NC_URL}.conf"
    a2enmod rewrite headers env dir mime
    systemctl restart apache2
    echo "✅ Apache konfiguriert."

    # 7. PHP-Einstellungen optimieren
    echo " Optimiere PHP-Einstellungen für Nextcloud..."
    PHP_INI_FILE=$(find /etc/php -name "php.ini" -and -path "*apache2*")
    sed -i "s/memory_limit = .*/memory_limit = 512M/" "$PHP_INI_FILE"
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = 10G/" "$PHP_INI_FILE"
    sed -i "s/post_max_size = .*/post_max_size = 10G/" "$PHP_INI_FILE"
    sed -i "s/;date.timezone =/date.timezone = Europe\/Berlin/" "$PHP_INI_FILE"
    systemctl restart apache2
    echo "✅ PHP optimiert."

    # 8. Nextcloud Installation via 'occ'-Befehl
    echo " Führe die Kommandozeilen-Installation von Nextcloud aus..."
    sudo -u www-data php "${NC_PATH}/occ" maintenance:install \
        --database "mysql" \
        --database-name "${NC_DB_NAME}" \
        --database-user "${NC_DB_USER}" \
        --database-pass "${NC_DB_PASS}" \
        --admin-user "${NC_ADMIN_USER}" \
        --admin-pass "${NC_ADMIN_PASS}" \
        --data-dir "/var/nextcloud_data"
    echo "✅ Nextcloud-Kerninstallation abgeschlossen."
    
    # 9. Post-Installation Konfiguration
    echo " Konfiguriere Trusted Domains und Caching..."
    # Trusted Domain hinzufügen. 0 ist localhost, 1 ist die Hauptdomain.
    sudo -u www-data php "${NC_PATH}/occ" config:system:set trusted_domains 1 --value="${NC_URL}"
    # Redis als Memory Cache konfigurieren
    sudo -u www-data php "${NC_PATH}/occ" config:system:set memcache.local --value '\OC\Memcache\APCu'
    sudo -u www-data php "${NC_PATH}/occ" config:system:set memcache.distributed --value '\OC\Memcache\Redis'
    sudo -u www-data php "${NC_PATH}/occ" config:system:set redis host --value 'localhost'
    sudo -u www-data php "${NC_PATH}/occ" config:system:set redis port --value '6379'
    echo "✅ Konfiguration abgeschlossen."

    # 10. Cronjob einrichten
    echo " Richte Cronjob für Hintergrundaufgaben ein..."
    (crontab -u www-data -l 2>/dev/null; echo "*/5  * * * * php -f ${NC_PATH}/cron.php") | crontab -u www-data -
    sudo -u www-data php "${NC_PATH}/occ" background:cron
    echo "✅ Cronjob eingerichtet."

    # 11. Optional: SSL mit Let's Encrypt einrichten
    read -p "Möchten Sie ein kostenloses SSL-Zertifikat mit Let's Encrypt einrichten? (empfohlen) (ja/nein): " setup_ssl
    if [[ "$setup_ssl" == "ja" ]]; then
        echo " Installiere Certbot für Let's Encrypt..."
        apt-get install -y certbot python3-certbot-apache
        echo " Fordere Zertifikat an und konfiguriere Apache für SSL..."
        certbot --apache --non-interactive --agree-tos --redirect -d "${NC_URL}" -m "admin@${NC_URL}"
        echo "✅ SSL erfolgreich eingerichtet."
        FINAL_URL="https://${NC_URL}"
    else
        FINAL_URL="http://${NC_URL}"
    fi

    # --- Abschluss ---
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    echo -e "\n\n🎉 Die Installation von Nextcloud war erfolgreich! 🎉"
    echo "------------------------------------------------------------------"
    echo "Sie können Nextcloud nun unter folgender Adresse erreichen:"
    echo -e "\n    \033[1m${FINAL_URL}\033[0m\n"
    echo "Ihre Anmeldedaten sind:"
    echo -e "  » Benutzername: \033[1m${NC_ADMIN_USER}\033[0m"
    echo -e "  » Passwort:     \033[1m${NC_ADMIN_PASS}\033[0m"
    echo ""
    echo "Das Datenverzeichnis befindet sich unter: /var/nextcloud_data"
    echo "------------------------------------------------------------------"
}

# Funktion zum Zurücksetzen des Admin-Passworts
reset_password() {
    echo "Setze ein neues Passwort für den Admin-Benutzer '${NC_ADMIN_USER}'."
    read -s -p "Bitte geben Sie das neue Passwort ein: " NEW_PASSWORD
    echo
    read -s -p "Bitte bestätigen Sie das neue Passwort: " CONFIRM_PASSWORD
    echo

    if [ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
        echo "❌ Die Passwörter stimmen nicht überein. Abbruch."
        exit 1
    fi
    
    if [ -z "$NEW_PASSWORD" ]; then
        echo "❌ Das Passwort darf nicht leer sein. Abbruch."
        exit 1
    fi

    sudo -u www-data php "${NC_PATH}/occ" user:resetpassword "${NC_ADMIN_USER}" --password-from-env <<< "OC_PASS=${NEW_PASSWORD}"
    
    echo "✅ Passwort für '${NC_ADMIN_USER}' wurde erfolgreich zurückgesetzt."
}

# --- Service-Verwaltungsfunktionen ---
check_status() {
    echo "Status der Nextcloud-Dienste:"
    systemctl status "${SERVICES[@]}"
}
start_services() {
    echo "Starte Nextcloud-Dienste..."
    systemctl start "${SERVICES[@]}"
    echo "✅ Dienste gestartet."
}
stop_services() {
    echo "Stoppe Nextcloud-Dienste..."
    systemctl stop "${SERVICES[@]}"
    echo "✅ Dienste gestoppt."
}
restart_services() {
    echo "Starte Nextcloud-Dienste neu..."
    systemctl restart "${SERVICES[@]}"
    echo "✅ Dienste neugestartet."
}


# ==============================================================================
# --- HAUPTLOGIK ---
# ==============================================================================

# Prüfen, ob das Skript als root ausgeführt wird
if [ "$(id -u)" -ne 0 ]; then
   echo "Dieses Skript muss als root ausgeführt werden." >&2
   exit 1
fi

# Prüfen, ob eine Statusdatei existiert
if [ -f "$STATE_FILE" ]; then
    echo "Eine bestehende Nextcloud-Installation wurde erkannt."
    source "$STATE_FILE"
    
    echo
    echo "================ NEXTCLOUD MANAGER ================"
    echo "Installation erkannt für URL '${NC_URL}' (Version: ${NC_VERSION})"
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
            echo "Option 6 gewählt: Neuinstallation."
            read -p "WARNUNG: Dies löscht die aktuelle Nextcloud-Installation vollständig. Sind Sie sicher? (ja/nein): " confirm
            if [[ "$confirm" == "ja" ]]; then
                cleanup
                echo "System wurde bereinigt. Bitte führen Sie das Skript erneut aus, um eine Neuinstallation zu starten."
            else
                echo "Abbruch."
            fi
            ;;
        7)
            echo "Option 7 gewählt: Vollständige Deinstallation."
            read -p "WARNUNG: Dies löscht ALLE Nextcloud-Daten endgültig. Sind Sie sicher? (ja/nein): " confirm
            if [[ "$confirm" == "ja" ]]; then
                cleanup
                echo "Nextcloud wurde vollständig entfernt."
            else
                echo "Abbruch."
            fi
            ;;
        8)
            echo "Abbruch."
            exit 0
            ;;
        *)
            echo "Ungültige Auswahl. Abbruch."
            exit 1
            ;;
    esac
else
    # Keine Statusdatei gefunden -> Erstinstallation
    echo "Willkommen zum Nextcloud-Installer."
    echo "Bitte geben Sie die Konfigurationsdetails für die Installation ein."
    echo "Drücken Sie Enter, um die Standardwerte in [Klammern] zu verwenden."
    echo ""

    # Abfrage der Konfigurationsdetails
    read -p "Nextcloud-Version, die installiert werden soll [31.0.8]: " NC_VERSION_INPUT
    NC_VERSION=${NC_VERSION_INPUT:-31.0.8} # Die von Ihnen gewünschte Version

    read -p "URL für Nextcloud (z.B. cloud.meinefirma.de): " NC_URL
    if [ -z "$NC_URL" ]; then echo "❌ Die URL darf nicht leer sein."; exit 1; fi

    read -p "Benutzername für den Nextcloud-Admin [admin]: " NC_ADMIN_USER_INPUT
    NC_ADMIN_USER=${NC_ADMIN_USER_INPUT:-admin}

    read -s -p "Passwort für den Nextcloud-Admin [Zufällig generiert]: " NC_ADMIN_PASS
    if [ -z "$NC_ADMIN_PASS" ]; then
        NC_ADMIN_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        echo -e "\nEin zufälliges Passwort wurde generiert: \033[1m${NC_ADMIN_PASS}\033[0m"
    else
        echo
    fi

    read -p "Name der MariaDB-Datenbank [nextcloud_db]: " NC_DB_NAME_INPUT
    NC_DB_NAME=${NC_DB_NAME_INPUT:-nextcloud_db}

    read -p "Benutzer für die MariaDB-Datenbank [nextcloud_user]: " NC_DB_USER_INPUT
    NC_DB_USER=${NC_DB_USER_INPUT:-nextcloud_user}
    
    read -s -p "Passwort für den MariaDB-Benutzer [Zufällig generiert]: " NC_DB_PASS
    if [ -z "$NC_DB_PASS" ]; then
        NC_DB_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        echo -e "\nEin zufälliges Passwort wurde generiert."
    else
        echo
    fi

    # Wichtige Variablen in die Statusdatei speichern
    {
        echo "NC_URL='${NC_URL}'"
        echo "NC_VERSION='${NC_VERSION}'"
        echo "NC_ADMIN_USER='${NC_ADMIN_USER}'"
        echo "NC_DB_NAME='${NC_DB_NAME}'"
        echo "NC_DB_USER='${NC_DB_USER}'"
    } > "$STATE_FILE"
    
    echo ""
    echo "Konfiguration abgeschlossen. Die Installation wird mit folgenden Werten gestartet:"
    echo "--------------------------------------------------"
    echo "Version:         ${NC_VERSION}"
    echo "URL:             ${NC_URL}"
    echo "Admin-Benutzer:  ${NC_ADMIN_USER}"
    echo "Admin-Passwort:  ${NC_ADMIN_PASS}"
    echo "DB-Name:         ${NC_DB_NAME}"
    echo "DB-Benutzer:     ${NC_DB_USER}"
    echo "DB-Passwort:     (wird nicht angezeigt)"
    echo "Installationspfad: ${NC_PATH}"
    echo "Datenverzeichnis: /var/nextcloud_data"
    echo "--------------------------------------------------"
    read -p "Drücken Sie Enter, um fortzufahren, oder Strg+C zum Abbrechen."

    installation
fi
