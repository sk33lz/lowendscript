#!/bin/bash

function check_install {
    if [ -z "`which "$1" 2>/dev/null`" ]
    then
        executable=$1
        shift
        while [ -n "$1" ]
        do
            DEBIAN_FRONTEND=noninteractive apt-get -q -y install "$1"
            print_info "$1 installed for $executable"
            shift
        done
    else
        print_warn "$2 already installed"
    fi
}

function check_remove {
    if [ -n "`which "$1" 2>/dev/null`" ]
    then
        DEBIAN_FRONTEND=noninteractive apt-get -q -y remove --purge "$2"
        print_info "$2 removed"
    else
        print_warn "$2 is not installed"
    fi
}

function check_sanity {
    # Do some sanity checking.
    if [ $(/usr/bin/id -u) != "0" ]
    then
        die 'Must be run by root user'
    fi

    if [ ! -f /etc/debian_version ]
    then
        die "Distribution is not supported"
    fi
}

function die {
    echo "ERROR: $1" > /dev/null 1>&2
    exit 1
}

function get_domain_name() {
    # Getting rid of the lowest part.
    domain=${1%.*}
    lowest=`expr "$domain" : '.*\.\([a-z][a-z]*\)'`
    case "$lowest" in
    com|net|org|gov|edu|co)
        domain=${domain%.*}
        ;;
    esac
    lowest=`expr "$domain" : '.*\.\([a-z][a-z]*\)'`
    [ -z "$lowest" ] && echo "$domain" || echo "$lowest"
}

function get_password() {
    # Check whether our local salt is present.
    SALT=/var/lib/radom_salt
    if [ ! -f "$SALT" ]
    then
        head -c 512 /dev/urandom > "$SALT"
        chmod 400 "$SALT"
    fi
    password=`(cat "$SALT"; echo $1) | md5sum | base64`
    echo ${password:0:13}
}

function install_dash {
    check_install dash dash
    rm -f /bin/sh
    ln -s dash /bin/sh
}

function install_dropbear {
    check_install dropbear dropbear
    check_install /usr/sbin/xinetd xinetd

    # Disable SSH
    touch /etc/ssh/sshd_not_to_be_run
    invoke-rc.d ssh stop

    # Enable dropbear to start. We are going to use xinetd as it is just
    # easier to configure and might be used for other things.
    cat > /etc/xinetd.d/dropbear <<END
service ssh
{
    socket_type     = stream
    only_from       = 0.0.0.0
    wait            = no
    user            = root
    protocol        = tcp
    server          = /usr/sbin/dropbear
    server_args     = -i
    disable         = no
}
END
    invoke-rc.d xinetd restart
}

function install_exim4 {
    check_install mail exim4
    if [ -f /etc/exim4/update-exim4.conf.conf ]
    then
        sed -i \
            "s/dc_eximconfig_configtype='local'/dc_eximconfig_configtype='internet'/" \
            /etc/exim4/update-exim4.conf.conf
        invoke-rc.d exim4 restart
    fi
}

function install_mysql {
    # Install the MySQL packages
    check_install mysqld mysql-server
    check_install mysql mysql-client

    # Install a low-end copy of the my.cnf to disable InnoDB, and then delete
    # all the related files.
    invoke-rc.d mysql stop
    rm -f /var/lib/mysql/ib*
    cat > /etc/mysql/conf.d/lowendbox.cnf <<END
[mysqld]
key_buffer = 8M
query_cache_size = 0
skip-innodb
END
    invoke-rc.d mysql start

    # Generating a new password for the root user.
    passwd=`get_password root@mysql`
    mysqladmin password "$passwd"
    cat > ~/.my.cnf <<END
[client]
user = root
password = $passwd
END
    chmod 600 ~/.my.cnf
}

function install_nginx {
    check_install nginx nginx
    
    # Need to increase the bucket size for Debian 5.
    cat > /etc/nginx/conf.d/lowendbox.conf <<END
server_names_hash_bucket_size 64;
END

    invoke-rc.d nginx restart
}

function install_php {
    check_install php-cgi php5-cgi php5-cli php5-mysql
    cat > /etc/init.d/php-cgi <<END
#!/bin/bash
### BEGIN INIT INFO
# Provides:          php-cgi
# Required-Start:    networking
# Required-Stop:     networking
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start the PHP FastCGI processes web server.
### END INIT INFO

PATH=/sbin:/bin:/usr/sbin:/usr/bin
NAME="php-cgi"
DESC="php-cgi"
PIDFILE="/var/lib/www/php.pid"
FCGIPROGRAM="/usr/bin/php-cgi"
FCGISOCKET="/var/lib/www/php.sock"
FCGIUSER="www-data"
FCGIGROUP="www-data"

if [ -e /etc/default/php-cgi ]
then
    source /etc/default/php-cgi
fi

[ -z "\$PHP_FCGI_CHILDREN" ] && PHP_FCGI_CHILDREN=1
[ -z "\$PHP_FCGI_MAX_REQUESTS" ] && PHP_FCGI_MAX_REQUESTS=5000

ALLOWED_ENV="PATH USER PHP_FCGI_CHILDREN PHP_FCGI_MAX_REQUESTS FCGI_WEB_SERVER_ADDRS"

set -e

. /lib/lsb/init-functions

case "\$1" in
start)
    unset E
    for i in \${ALLOWED_ENV}; do
        E="\${E} \${i}=\${!i}"
    done
    log_daemon_msg "Starting \$DESC" \$NAME
    env - \${E} start-stop-daemon --start -x \$FCGIPROGRAM -p \$PIDFILE \\
        -c \$FCGIUSER:\$FCGIGROUP -b -m -- -b \$FCGISOCKET
    log_end_msg 0
    ;;
stop)
    log_daemon_msg "Stopping \$DESC" \$NAME
    if start-stop-daemon --quiet --stop --oknodo --retry 30 \\
        --pidfile \$PIDFILE --exec \$FCGIPROGRAM
    then
        rm -f \$PIDFILE
        log_end_msg 0
    else
        log_end_msg 1
    fi
    ;;
restart|force-reload)
    \$0 stop
    sleep 1
    \$0 start
    ;;
*)
    echo "Usage: \$0 {start|stop|restart|force-reload}" >&2
    exit 1
    ;;
esac
exit 0
END
    chmod 755 /etc/init.d/php-cgi
    mkdir -p /var/lib/www
    chown www-data:www-data /var/lib/www

    cat > /etc/nginx/fastcgi_php <<END
location ~ \.php$ {
    include /etc/nginx/fastcgi_params;

    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    if (-f \$request_filename) {
        fastcgi_pass unix:/var/lib/www/php.sock;
    }
}
END
    update-rc.d php-cgi defaults
    invoke-rc.d php-cgi start
}

function install_syslogd {
    # We just need a simple vanilla syslogd. Also there is no need to log to
    # so many files (waste of fd). Just dump them into
    # /var/log/(cron/mail/messages)
    check_install /usr/sbin/syslogd inetutils-syslogd
    invoke-rc.d inetutils-syslogd stop

    for file in /var/log/*.log /var/log/mail.* /var/log/debug /var/log/syslog
    do
        [ -f "$file" ] && rm -f "$file"
    done
    for dir in fsck news
    do
        [ -d "/var/log/$dir" ] && rm -rf "/var/log/$dir"
    done

    cat > /etc/syslog.conf <<END
*.*;mail.none;cron.none -/var/log/messages
cron.*                  -/var/log/cron
mail.*                  -/var/log/mail
END

    [ -d /etc/logrotate.d ] || mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/inetutils-syslogd <<END
/var/log/cron
/var/log/mail
/var/log/messages {
   rotate 4
   weekly
   missingok
   notifempty
   compress
   sharedscripts
   postrotate
      /etc/init.d/inetutils-syslogd reload >/dev/null
   endscript
}
END

    invoke-rc.d inetutils-syslogd start
}

function install_wordpress {
    check_install wget wget
    if [ -z "$1" ]
    then
        die "Usage: `basename $0` wordpress <hostname>"
    fi

    # Downloading the WordPress' latest and greatest distribution.
    mkdir /tmp/wordpress.$$
    wget -O - http://wordpress.org/latest.tar.gz | \
        tar zxf - -C /tmp/wordpress.$$
    mv /tmp/wordpress.$$/wordpress "/var/www/$1"
    rm -rf /tmp/wordpress.$$
    chown root:root -R "/var/www/$1"

    # Setting up the MySQL database
    dbname=`echo $1 | tr . _`
	echo Database Name = 'echo $1 | tr . _'
    userid=`get_domain_name $1`
    # MySQL userid cannot be more than 15 characters long
    userid="${userid:0:15}"
    passwd=`get_password "$userid@mysql"`
    cp "/var/www/$1/wp-config-sample.php" "/var/www/$1/wp-config.php"
    sed -i "s/database_name_here/$dbname/; s/username_here/$userid/; s/password_here/$passwd/" \
        "/var/www/$1/wp-config.php"
    mysqladmin create "$dbname"
    echo "GRANT ALL PRIVILEGES ON \`$dbname\`.* TO \`$userid\`@localhost IDENTIFIED BY '$passwd';" | \
        mysql

    # Setting up Nginx mapping
    cat > "/etc/nginx/sites-enabled/$1.conf" <<END
server {
    server_name $1;
    root /var/www/$1;
    include /etc/nginx/fastcgi_php;
    location / {
        index index.php;
        if (!-e \$request_filename) {
            rewrite ^(.*)$  /index.php last;
        }
    }
}
END
    invoke-rc.d nginx reload
}

function install_htmlsite {
    # Setup folder
	mkdir /var/www/$1
	
	# Setup default index.html file
	cat > "/var/www/$1/index.html" <<END
Hello World
END
    
    # Setting up Nginx mapping
    cat > "/etc/nginx/sites-enabled/$1.conf" <<END
server {
    server_name $1;
    root /var/www/$1;
    include /etc/nginx/fastcgi_php;
    location / {
        index index.php index.html;
        if (!-e \$request_filename) {
            rewrite ^(.*)$  /index.php last;
        }
    }
}
END
    service nginx restart
}

function install_drupal6 {
    check_install wget
    if [ -z "$1" ]
    then
        die "Usage: `basename $0` drupal <hostname>"
    fi
	
	#Download PHP5-gd package
	apt-get -q -y install php5-gd
    /etc/init.d/php-cgi restart
	
    # Downloading the Drupal' latest and greatest distribution.
    mkdir /tmp/drupal.$$
    wget -O - http://ftp.drupal.org/files/projects/drupal-6.26.tar.gz | \
        tar zxf - -C /tmp/drupal.$$/
    mkdir /var/www/$1
    cp -Rf /tmp/drupal.$$/drupal*/* "/var/www/$1"
    rm -rf /tmp/drupal*
    chown root:root -R "/var/www/$1"

    # Setting up the MySQL database
    dbname=`echo $1 | tr . _`
	
	# MySQL dbname cannot be more than 15 characters long
    dbname="${dbname:0:15}"
    
	userid=`get_domain_name $1`
    
	# MySQL userid cannot be more than 15 characters long
    userid="${userid:0:15}"
    passwd=`get_password "$userid@mysql"`
    cp "/var/www/$1/sites/default/default.settings.php" "/var/www/$1/sites/default/settings.php"
	chmod 777 /var/www/$1/sites/default/settings.php
	mkdir /var/www/$1/sites/default/files
	chmod -R 777 /var/www/$1/sites/default/files
    mysqladmin create "$dbname"
    echo "GRANT ALL PRIVILEGES ON \`$dbname\`.* TO \`$userid\`@localhost IDENTIFIED BY '$passwd';" | \
        mysql

	#Copy DB Name, User, and Pass to settings.php and set to read only.
	sed -i "91 s/username/$userid/; 91 s/password/$passwd/; 91 s/databasename/$dbname/" "/var/www/$1/sites/default/settings.php"
	chmod 644 /var/www/$1/sites/default/settings.php
    
	# Setting up Nginx mapping
    cat > "/etc/nginx/sites-enabled/$1.conf" <<END
server {
    server_name $1;
    root /var/www/$1;
    include /etc/nginx/fastcgi_php;
    # common Drupal configuration options.
# Make sure to set $socket to a fastcgi socket.

        location = /favicon.ico {
                log_not_found off;
                access_log off;
        }

        ###
        ### support for http://drupal.org/project/robotstxt module
        ###
        location = /robots.txt {
                access_log off;
                try_files \$uri @drupal;
        }

        # no access to php files in subfolders.
        location ~ .+/.*\.php$ {
                return 403;
        }

        location ~* \.(inc|engine|install|info|module|sh|sql|theme|tpl\.php|xtmpl|Entries|Repository|Root|jar|java|class)$ {
                deny all;
        }

        location ~ \.php$ {
                # Required for private files, otherwise they slow down extremely.
                keepalive_requests 0;
        }

        # private files protection
        location ~ ^/sites/.*/private/ {
                access_log off;
                deny all;
        }

        location ~* ^(?!/system/files).*\.(js|css|png|jpg|jpeg|gif|ico)$ {
                # If the image does not exist, maybe it must be generated by drupal (imagecache)
                try_files \$uri @drupal;
                expires 7d;
                log_not_found off;
        }

        ###
        ### deny direct access to backups
        ###
        location ~* ^/sites/.*/files/backup_migrate/ {
                access_log off;
                deny all;
        }

        location ~ ^/(.*) {
                try_files \$uri /index.php?q=\$1&\$args;
        }

        location @drupal {
                # Some modules enforce no slash (/) at the end of the URL
                # Else this rewrite block wouldn't be needed (GlobalRedirect)
                rewrite ^/(.*)$ /index.php?q=\$1;
        }
#And here is the configuration for passing the request to PHP FastCGI (fastcgi.conf):

# common fastcgi configuration for PHP files

                fastcgi_split_path_info ^(.+\.php)(/.+)$;
                #NOTE: You should have "cgi.fix_pathinfo = 0;" in php.ini
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
                fastcgi_intercept_errors on;
                fastcgi_read_timeout 6000;
}
END
    invoke-rc.d nginx reload
	
	
	#Echo DB Name
	echo -e $COL_BLUE"*** COPY FOR SAFE KEEPING ***"
	COL_BLUE="\x1b[34;01m"
    COL_RESET="\x1b[39;49;00m"
    echo -e $COL_BLUE"Database Name: "$COL_RESET"$dbname"
	
    #Echo DB User value
	echo -e $COL_BLUE"Database User: "$COL_RESET"${userid:0:15}"
	
	#Echo DB Password
	echo -e $COL_BLUE"Database Password: "$COL_RESET"$passwd"
	
	#Echo Install URL
	echo -e $COL_BLUE"Visit to finalize installation: "$COL_RESET"http://$1/install.php"
}

function install_drupal7 {
    check_install wget
    if [ -z "$1" ]
    then
        die "Usage: `basename $0` drupal <hostname>"
    fi
	
	#Download PHP5-gd package
	apt-get -q -y install php5-gd
    /etc/init.d/php-cgi restart
	
    # Downloading the Drupal' latest and greatest distribution.
    mkdir /tmp/drupal.$$
    wget -O - http://ftp.drupal.org/files/projects/drupal-7.15.tar.gz | \
        tar zxf - -C /tmp/drupal.$$/
    mkdir /var/www/$1
    cp -Rf /tmp/drupal.$$/drupal*/* "/var/www/$1"
    rm -rf /tmp/drupal*
    chown root:root -R "/var/www/$1"

    # Setting up the MySQL database
    dbname=`echo $1 | tr . _`
	
	# MySQL dbname cannot be more than 15 characters long
    dbname="${dbname:0:15}"
	
    userid=`get_domain_name $1`
	
    # MySQL userid cannot be more than 15 characters long
    userid="${userid:0:15}"
    passwd=`get_password "$userid@mysql"`
	
	# Copy default.settings.php to settings.php and set write permissions.
    cp "/var/www/$1/sites/default/default.settings.php" "/var/www/$1/sites/default/settings.php"
	chmod 777 /var/www/$1/sites/default/settings.php
	mkdir /var/www/$1/sites/default/files
	chmod -R 777 /var/www/$1/sites/default/files
    
	# Create MySQL database
	mysqladmin create "$dbname"
    echo "GRANT ALL PRIVILEGES ON \`$dbname\`.* TO \`$userid\`@localhost IDENTIFIED BY '$passwd';" | \
        mysql
		
    #Copy DB Name, User, and Pass to settings.php and set to read only.
    echo "\$databases['default']['default'] = array(" >> /var/www/$1/sites/default/settings.php
    echo "'driver' => 'mysql'," >> /var/www/$1/sites/default/settings.php
    echo "'database' => '$dbname'," >> /var/www/$1/sites/default/settings.php
    echo "'username' => '$userid'," >> /var/www/$1/sites/default/settings.php
    echo "'password' => '$passwd'," >> /var/www/$1/sites/default/settings.php
    echo "'host' => 'localhost');" >> /var/www/$1/sites/default/settings.php
    chmod 644 /var/www/$1/sites/default/settings.php
	
	#Echo DB Name
	echo -e $COL_BLUE"*** COPY FOR SAFE KEEPING ***"
	COL_BLUE="\x1b[34;01m"
    COL_RESET="\x1b[39;49;00m"
    echo -e $COL_BLUE"Database Name: "$COL_RESET"$dbname"
	
    #Echo DB User value
	echo -e $COL_BLUE"Database User: "$COL_RESET"${userid:0:15}"
	
	#Echo DB Password
	echo -e $COL_BLUE"Database Password: "$COL_RESET"$passwd"
	
	#Echo Install URL
	echo -e $COL_BLUE"Visit to finalize installation: "$COL_RESET"http://$1/install.php"
	


    # Setting up Nginx mapping
    cat > "/etc/nginx/sites-enabled/$1.conf" <<END
server {
    server_name $1;
    root /var/www/$1;
    include /etc/nginx/fastcgi_php;
    # common Drupal configuration options.
# Make sure to set $socket to a fastcgi socket.

        location = /favicon.ico {
                log_not_found off;
                access_log off;
        }

        ###
        ### support for http://drupal.org/project/robotstxt module
        ###
        location = /robots.txt {
                access_log off;
                try_files \$uri @drupal;
        }

        # no access to php files in subfolders.
        location ~ .+/.*\.php$ {
                return 403;
        }

        location ~* \.(inc|engine|install|info|module|sh|sql|theme|tpl\.php|xtmpl|Entries|Repository|Root|jar|java|class)$ {
                deny all;
        }

        location ~ \.php$ {
                # Required for private files, otherwise they slow down extremely.
                keepalive_requests 0;
        }

        # private files protection
        location ~ ^/sites/.*/private/ {
                access_log off;
                deny all;
        }

        location ~* ^(?!/system/files).*\.(js|css|png|jpg|jpeg|gif|ico)$ {
                # If the image does not exist, maybe it must be generated by drupal (imagecache)
                try_files \$uri @drupal;
                expires 7d;
                log_not_found off;
        }

        ###
        ### deny direct access to backups
        ###
        location ~* ^/sites/.*/files/backup_migrate/ {
                access_log off;
                deny all;
        }

        location ~ ^/(.*) {
                try_files \$uri /index.php?q=\$1&\$args;
        }

        location @drupal {
                # Some modules enforce no slash (/) at the end of the URL
                # Else this rewrite block wouldn't be needed (GlobalRedirect)
                rewrite ^/(.*)$ /index.php?q=\$1;
        }
#And here is the configuration for passing the request to PHP FastCGI (fastcgi.conf):

# common fastcgi configuration for PHP files

                fastcgi_split_path_info ^(.+\.php)(/.+)$;
                #NOTE: You should have "cgi.fix_pathinfo = 0;" in php.ini
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
                fastcgi_intercept_errors on;
                fastcgi_read_timeout 6000;
}
END
    invoke-rc.d nginx reload
}

function install_magento {
  ##Check for Wget
  check_install wget
    if [ -z "$1" ]
    then
        die "Usage: `basename $0` magento <hostname>"
    fi
  #Download PHP5-gd package
  apt-get -q -y install php5-gd
  /etc/init.d/php-cgi restart
	
  # Downloading the Magento's latest and greatest distribution.
  mkdir /tmp/magento.$$
  wget -O - http://www.magentocommerce.com/downloads/assets/1.7.0.2/magento-1.7.0.2.tar.gz | \
  tar zxf - -C /tmp/magento.$$/
  mkdir /var/www/$1
  cp -Rf /tmp/magento.$$/magento*/* "/var/www/$1"
  rm -rf /tmp/magento*
  chown root:root -R "/var/www/$1"

  # Setting up the MySQL database
  dbname=`echo $1 | tr . _`
	
  # MySQL dbname cannot be more than 15 characters long
  dbname="${dbname:0:15}"
  userid=`get_domain_name $1`
	
  # MySQL userid cannot be more than 15 characters long
  userid="${userid:0:15}"
  passwd=`get_password "$userid@mysql"`
  
  # Setup Nginx Magento config file for domain.
  cat > "/etc/nginx/sites-enabled/magento/$1.conf" <<END
      server {
        listen 80;
        server_name $1;
        rewrite / $scheme://$1$request_uri permanent; ## Forcibly remove www
    }
     
    server {
        listen 80 default;
    ## SSL directives might go here
        server_name $1 *.$1; ## Domain is here twice so server_name_in_redirect will not favor the www
        root /var/www/vhosts/$1;
     
        location / {
            index index.html index.php; ## Allow a static html file to be shown first
            try_files $uri $uri/ @handler; ## If missing pass the URI to Magento's front handler
            expires 30d; ## Assume all files are cachable
        }
     
        ## These locations would be hidden by .htaccess normally
        location ^~ /app/                { deny all; }
        location ^~ /includes/           { deny all; }
        location ^~ /lib/                { deny all; }
        location ^~ /media/downloadable/ { deny all; }
        location ^~ /pkginfo/            { deny all; }
        location ^~ /report/config.xml   { deny all; }
        location ^~ /var/                { deny all; }
     
        location /var/export/ { ## Allow admins only to view export folder
            auth_basic           "Restricted"; ## Message shown in login window
            auth_basic_user_file htpasswd; ## See /etc/nginx/htpassword
            autoindex            on;
        }
     
        location  /. { ## Disable .htaccess and other hidden files
            return 404;
        }
     
        location @handler { ## Magento uses a common front handler
            rewrite / /index.php;
        }
     
        location ~ .php/ { ## Forward paths like /js/index.php/x.js to relevant handler
            rewrite ^(.*.php)/ $1 last;
        }
     
        location ~ .php$ { ## Execute PHP scripts
            if (!-e $request_filename) { rewrite / /index.php last; } ## Catch 404s that try_files miss
     
            expires        off; ## Do not cache dynamic content
            fastcgi_pass   127.0.0.1:9000;
            fastcgi_param  HTTPS $fastcgi_https;
            fastcgi_param  SCRIPT_FILENAME  $document_root$fastcgi_script_name;
            fastcgi_param  MAGE_RUN_CODE default; ## Store code is defined in administration > Configuration > Manage Stores
            fastcgi_param  MAGE_RUN_TYPE store;
            include        fastcgi_params; ## See /etc/nginx/fastcgi_params
        }
    }
END
  invoke-rc.d nginx reload
}

function install_mariadb {
  sudo apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 0xcbcb082a1bb943db
  sudo apt-get update
  sudo apt-get install mariadb-server-5.5
}

function install_csf {
  mkdir /tmp/configserver.$$
    wget -O - http://www.configserver.com/free/csf.tgz | \
        tar zxf - -C /tmp/configserver.$$
	cd /tmp/configserver.$$
	sh install.sh
	rm -rf /tmp/configserver*
}

function print_info {
    echo -n -e '\e[1;36m'
    echo -n $1
    echo -e '\e[0m'
}

function print_warn {
    echo -n -e '\e[1;33m'
    echo -n $1
    echo -e '\e[0m'
}

function remove_unneeded {
    # Some Debian have portmap installed. We don't need that.
    check_remove /sbin/portmap portmap

    # Remove rsyslogd, which allocates ~30MB privvmpages on an OpenVZ system,
    # which might make some low-end VPS inoperatable. We will do this even
    # before running apt-get update.
    check_remove /usr/sbin/rsyslogd rsyslog

    # Other packages that seem to be pretty common in standard OpenVZ
    # templates.
    check_remove /usr/sbin/apache2 'apache2*'
    check_remove /usr/sbin/named bind9
    check_remove /usr/sbin/smbd 'samba*'
    check_remove /usr/sbin/nscd nscd

    # Need to stop sendmail as removing the package does not seem to stop it.
    if [ -f /usr/lib/sm.bin/smtpd ]
    then
        invoke-rc.d sendmail stop
        check_remove /usr/lib/sm.bin/smtpd 'sendmail*'
    fi
}

function update_upgrade {
    # Run through the apt-get update/upgrade first. This should be done before
    # we try to install any package
    apt-get -q -y update
    apt-get -q -y upgrade
}

########################################################################
# START OF PROGRAM
########################################################################
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

check_sanity
case "$1" in
exim4)
    install_exim4
    ;;
mysql)
    install_mysql
    ;;
nginx)
    install_nginx
    ;;
php)
    install_php
    ;;
system)
    remove_unneeded
    update_upgrade
    install_dash
    install_syslogd
    install_dropbear
    ;;
htmlsite)
    install_htmlsite $2
	;;
drupal6)
    install_drupal6 $2
	;;
drupal7)
    install_drupal7 $2
	;;
wordpress)
    install_wordpress $2
    ;;
*)
    echo 'Usage:' `basename $0` '[option]'
    echo 'Available option:'
    for option in system exim4 mysql nginx php wordpress drupal6 drupal7 htmlsite
    do
        echo '  -' $option
    done
    ;;
esac
