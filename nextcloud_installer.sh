#!/bin/bash

# ==========================================================
# Nextcloud Installer and Management Script for LXC Container
# Version: 1.0
# Author: Gemini
# ==========================================================

# --- Konfigurationsvariablen ---
NEXTCLOUD_BASE_DIR="/var/www"
NEXTCLOUD_DIR="${NEXTCLOUD_BASE_DIR}/nextcloud"
APACHE_CONF="/etc/apache2/sites-available/nextcloud.conf"
APACHE_SSL_CONF="/etc/apache2/sites-available/nextcloud-ssl.conf"
PHP_CONF="/etc/php/8.2/apache2/php.ini"  # Passen Sie die PHP-Version ggf. an
MYSQL_ROOT_PASS=""
DB_USER=""
DB_PASS=""
DB_NAME=""
ADMIN_USER=""
ADMIN_PASS=""
NEXTCLOUD_URL=""
NEXTCLOUD_VERSION="latest"  # Nextcloud 31.0.0 ist die aktuelle Stable-Version

# --- Farben für die Ausgabe ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Hilfsfunktionen ---

log_info() {
    echo -e "${CYAN}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Dieses Skript muss mit Root-Rechten ausgeführt werden."
        exit 1
    fi
}

check_dependencies() {
    if ! command -v apache2 &> /dev/null || ! command -v mariadb &> /dev/null || ! command -v php &> /dev/null; then
        return 1
    fi
    return 0
}

# --- Installationsschritte ---

install_nextcloud() {
    log_info "Starte die Nextcloud-Installation..."

    # Abfrage der Benutzerinformationen
    read -p "Geben Sie den MariaDB-Root-Passwort ein: " MYSQL_ROOT_PASS
    read -p "Geben Sie den gewünschten Nextcloud-Datenbankbenutzer ein: " DB_USER
    read -p "Geben Sie das Passwort für den Datenbankbenutzer ein: " DB_PASS
    read -p "Geben Sie den Namen der Nextcloud-Datenbank ein: " DB_NAME
    read -p "Geben Sie den Nextcloud-Admin-Benutzername ein: " ADMIN_USER
    read -p "Geben Sie das Passwort für den Nextcloud-Admin ein: " ADMIN_PASS
    read -p "Geben Sie die URL ein, unter der Nextcloud erreichbar sein soll (z.B. cloud.ihredomain.de): " NEXTCLOUD_URL
    read -p "Geben Sie die Nextcloud-Version ein (z.B. 31.0.0 oder 'latest'): " NEXTCLOUD_VERSION

    # 1. System aktualisieren
    log_info "Aktualisiere das System..."
    apt-get update && apt-get upgrade -y
    
    # 2. Apache2, MariaDB und PHP installieren
    log_info "Installiere Apache2, MariaDB und PHP..."
    apt-get install -y apache2 mariadb-server php-fpm libapache2-mod-php php-mysql php-mbstring php-zip php-gd php-curl php-xml php-imagick php-intl php-bcmath php-gmp php-json php-common php-cli php-fpm
    
    # 3. Apache-Module aktivieren
    log_info "Aktiviere Apache-Module..."
    a2enmod rewrite dir env headers mime setenvif ssl
    
    # 4. MariaDB konfigurieren und Datenbank/Benutzer anlegen
    log_info "Konfiguriere MariaDB und lege Datenbank an..."
    mysql -u root -p"${MYSQL_ROOT_PASS}" <<EOF
    CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
    CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
    GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
    FLUSH PRIVILEGES;
EOF
    
    # 5. PHP-Einstellungen anpassen
    log_info "Passe PHP-Einstellungen an..."
    if [ -f "$PHP_CONF" ]; then
        sed -i 's/memory_limit = 128M/memory_limit = 512M/' "$PHP_CONF"
        sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 1024M/' "$PHP_CONF"
        sed -i 's/post_max_size = 8M/post_max_size = 1024M/' "$PHP_CONF"
        sed -i 's/;date.timezone =/date.timezone = Europe\/Berlin/' "$PHP_CONF"
        log_success "PHP-Einstellungen erfolgreich angepasst."
    else
        log_error "PHP-Konfigurationsdatei $PHP_CONF nicht gefunden."
    fi

    # 6. Nextcloud herunterladen und entpacken
    log_info "Lade Nextcloud Version ${NEXTCLOUD_VERSION} herunter..."
    # Nextcloud Download-Link
    if [ "$NEXTCLOUD_VERSION" == "latest" ]; then
        DOWNLOAD_URL="https://download.nextcloud.com/server/releases/latest.zip"
    else
        DOWNLOAD_URL="https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip"
    fi

    wget -O /tmp/nextcloud.zip "${DOWNLOAD_URL}"
    unzip /tmp/nextcloud.zip -d ${NEXTCLOUD_BASE_DIR}
    
    # 7. Berechtigungen setzen
    log_info "Setze Dateiberechtigungen..."
    chown -R www-data:www-data ${NEXTCLOUD_DIR}
    
    # 8. Apache Virtual Host erstellen
    log_info "Erstelle Apache Virtual Host Konfiguration..."
    cat <<EOF > ${APACHE_CONF}
<VirtualHost *:80>
    ServerName ${NEXTCLOUD_URL}
    DocumentRoot ${NEXTCLOUD_DIR}
    
    <Directory ${NEXTCLOUD_DIR}>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/nextcloud-error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud-access.log combined
</VirtualHost>
EOF
    
    # 9. Apache SSL Virtual Host erstellen (selbstsigniert)
    log_info "Erstelle selbstsignierte SSL-Konfiguration..."
    mkdir -p /etc/apache2/ssl/
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/apache2/ssl/nextcloud.key \
        -out /etc/apache2/ssl/nextcloud.crt \
        -subj "/C=DE/ST=NRW/L=Duesseldorf/O=MyCompany/CN=${NEXTCLOUD_URL}"

    cat <<EOF > ${APACHE_SSL_CONF}
<VirtualHost *:443>
    ServerName ${NEXTCLOUD_URL}
    DocumentRoot ${NEXTCLOUD_DIR}

    <Directory ${NEXTCLOUD_DIR}>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    SSLEngine On
    SSLCertificateFile /etc/apache2/ssl/nextcloud.crt
    SSLCertificateKeyFile /etc/apache2/ssl/nextcloud.key

    ErrorLog \${APACHE_LOG_DIR}/nextcloud-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud-ssl-access.log combined
</VirtualHost>
EOF
    
    # 10. Konfiguration aktivieren und Apache neu starten
    log_info "Aktiviere Apache-Konfigurationen und starte neu..."
    a2dissite 000-default.conf
    a2ensite nextcloud.conf
    a2ensite nextcloud-ssl.conf
    systemctl restart apache2
    
    # 11. Nextcloud über die Kommandozeile installieren
    log_info "Führe Nextcloud CLI-Installation aus..."
    sudo -u www-data php ${NEXTCLOUD_DIR}/occ maintenance:install \
        --database "mysql" \
        --database-name "${DB_NAME}" \
        --database-user "${DB_USER}" \
        --database-pass "${DB_PASS}" \
        --admin-user "${ADMIN_USER}" \
        --admin-pass "${ADMIN_PASS}"
    
    # 12. Trusted Domain hinzufügen
    log_info "Füge die URL ${NEXTCLOUD_URL} zu den vertrauenswürdigen Domains hinzu..."
    sudo -u www-data php ${NEXTCLOUD_DIR}/occ config:system:set trusted_domains 1 --value="${NEXTCLOUD_URL}"

    # Letzte Prüfungen
    systemctl restart apache2
    log_success "Nextcloud wurde erfolgreich installiert."
    log_success "Sie sollten nun Nextcloud unter https://${NEXTCLOUD_URL} erreichen können."
    
    # 13. Nextcloud Cron Job einrichten
    log_info "Richte Nextcloud Cron Job ein..."
    (crontab -l 2>/dev/null; echo "*/5 * * * * sudo -u www-data php ${NEXTCLOUD_DIR}/occ system:cron") | crontab -
    log_success "Cron Job wurde eingerichtet."
    
}

# --- Management-Funktionen ---

manage_services() {
    clear
    log_info "Nextcloud Service-Verwaltung"
    echo "------------------------------"
    echo "1. Status der Dienste anzeigen"
    echo "2. Dienste starten"
    echo "3. Dienste stoppen"
    echo "4. Dienste neustarten"
    echo "0. Zurück zum Hauptmenü"
    echo "------------------------------"
    read -p "Wählen Sie eine Option: " choice
    
    case $choice in
        1)
            log_info "Status von Apache2:"
            systemctl status apache2 | grep Active
            log_info "Status von MariaDB:"
            systemctl status mariadb | grep Active
            ;;
        2)
            log_info "Starte Dienste..."
            systemctl start apache2
            systemctl start mariadb
            log_success "Dienste gestartet."
            ;;
        3)
            log_info "Stoppe Dienste..."
            systemctl stop apache2
            systemctl stop mariadb
            log_success "Dienste gestoppt."
            ;;
        4)
            log_info "Starte Dienste neu..."
            systemctl restart apache2
            systemctl restart mariadb
            log_success "Dienste neugestartet."
            ;;
        0)
            return
            ;;
        *)
            log_error "Ungültige Auswahl."
            ;;
    esac
    sleep 2
}

manage_installation() {
    clear
    log_info "Nextcloud Installations-Verwaltung"
    echo "------------------------------"
    echo "1. Nextcloud deinstallieren (ACHTUNG: Alle Daten werden gelöscht!)"
    echo "2. Nextcloud neuinstallieren"
    echo "3. Passwort des Admin-Benutzers ändern"
    echo "0. Zurück zum Hauptmenü"
    echo "------------------------------"
    read -p "Wählen Sie eine Option: " choice
    
    case $choice in
        1)
            uninstall_nextcloud
            ;;
        2)
            uninstall_nextcloud
            install_nextcloud
            ;;
        3)
            change_admin_password
            ;;
        0)
            return
            ;;
        *)
            log_error "Ungültige Auswahl."
            ;;
    esac
    sleep 2
}

uninstall_nextcloud() {
    read -p "SIND SIE SICHER? Dies löscht ALLE Nextcloud-Daten. [j/N]: " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        log_info "Deinstallation abgebrochen."
        return
    fi
    
    log_info "Starte die Deinstallation von Nextcloud..."
    
    # 1. Dienste stoppen
    systemctl stop apache2 mariadb
    
    # 2. Nextcloud-Verzeichnis löschen
    log_info "Lösche Nextcloud-Dateien..."
    rm -rf ${NEXTCLOUD_DIR}
    
    # 3. Datenbank löschen
    read -p "Geben Sie das MariaDB-Root-Passwort ein, um die Datenbank zu löschen: " MYSQL_ROOT_PASS
    if [ -n "${DB_NAME}" ]; then
        log_info "Lösche Datenbank ${DB_NAME} und Benutzer ${DB_USER}..."
        mysql -u root -p"${MYSQL_ROOT_PASS}" <<EOF
        DROP DATABASE IF EXISTS ${DB_NAME};
        DROP USER IF EXISTS '${DB_USER}'@'localhost';
        FLUSH PRIVILEGES;
EOF
        log_success "Datenbank erfolgreich gelöscht."
    else
        log_error "Datenbankname nicht gesetzt. Kann nicht löschen."
    fi
    
    # 4. Apache-Konfigurationen entfernen
    log_info "Entferne Apache-Konfigurationen..."
    a2dissite nextcloud.conf
    a2dissite nextcloud-ssl.conf
    rm -f ${APACHE_CONF} ${APACHE_SSL_CONF}
    
    # 5. Cron Job entfernen
    log_info "Entferne Cron Job..."
    (crontab -l 2>/dev/null | grep -v 'occ system:cron') | crontab -
    
    # 6. Dienste starten
    systemctl restart apache2
    
    log_success "Nextcloud wurde vollständig deinstalliert."
}

change_admin_password() {
    if [ ! -d "${NEXTCLOUD_DIR}" ]; then
        log_error "Nextcloud ist nicht installiert. Installation zuerst durchführen."
        return
    fi
    
    read -p "Geben Sie den Nextcloud-Admin-Benutzername ein: " admin_user_change
    read -s -p "Geben Sie das neue Passwort ein: " new_password
    echo ""
    read -s -p "Bestätigen Sie das neue Passwort: " confirm_password
    echo ""
    
    if [ "${new_password}" != "${confirm_password}" ]; then
        log_error "Passwörter stimmen nicht überein."
        return
    fi
    
    log_info "Ändere Passwort für Benutzer ${admin_user_change}..."
    sudo -u www-data php ${NEXTCLOUD_DIR}/occ user:resetpassword "${admin_user_change}"
    
    log_success "Passwort für ${admin_user_change} erfolgreich geändert. Sie müssen es nun manuell in der Konsole eingeben."
    
}

# --- Hauptmenü ---

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}=======================================${NC}"
        echo -e "${CYAN} Nextcloud Installations- & Management-Skript ${NC}"
        echo -e "${CYAN}=======================================${NC}"
        echo "1. Nextcloud installieren"
        echo "2. Nextcloud Dienste verwalten (Start/Stop/Status)"
        echo "3. Nextcloud Installation verwalten (Deinstallieren/Neuinstallieren/Passwort ändern)"
        echo "0. Beenden"
        echo "---------------------------------------"
        read -p "Wählen Sie eine Option: " main_choice
        
        case $main_choice in
            1)
                install_nextcloud
                ;;
            2)
                manage_services
                ;;
            3)
                manage_installation
                ;;
            0)
                log_info "Skript beendet. Bis bald! 👋"
                exit 0
                ;;
            *)
                log_error "Ungültige Auswahl."
                sleep 2
                ;;
        esac
    done
}

# --- Skriptausführung ---
check_root
main_menu
