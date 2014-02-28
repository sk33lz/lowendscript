A simple bash shell script to optimize your Debian or Ubuntu VPS server for serving PHP and MySQL driven website platforms like Drupal and Wordpress.

### TESTED ON
* Ubuntu 10.04 LTS, Ubuntu 12.04 LTS, Ubuntu 13.04
* Debian 5, Debian 6

### INSTALLATION
Download setup-debian.sh using one of the following commands:

    wget --no-check-certificate https://github.com/dhamaniasad/lowendscript/raw/master/setup-debian.sh
	
or

    git clone git://github.com/dhamaniasad/lowendscript.git

### USAGE
This script should be run by the root user for maximum compatibility.

#### Install System Tools 
Installs Dropbear, cron, and inetutils-syslog (replaces rsyslog), htop, smartmontools

Command:    
  
    bash setup-debian.sh system
  
#### Install ConfigServer Firewall
Installs Config Server Firewall for server security and intrusion detection.
Edit the /etc/csf/csf.cfg file to add your email address, or enable specific ports.

Command:
  
    bash setup-debian.sh csf
  
* Install Exim4 Mail Server 
  - Lightweight replacement for sendmail. Re-configured to allow Internet delivery.

  Command:    
  
  bash setup-debian.sh exim4

* Install Nginx HTTP Server
  - Low memory footprint httpd replacement for Apache web server.

  Command:    
  
  bash setup-debian.sh nginx

* Install MySQL Database Server
  - Re-configured to remove innodb support, remove query cache, and reduce key buffer size.

  Command:    
  
  bash setup-debian.sh mysql

* Install PHP FastCGI.
  - Built-in FastCGI running only 1 child process with respawn after 5,000 request.

  Command:    
  
  bash setup-debian.sh php

* Install Wordpress 
  - Installs the latet version of Wordpress. Then creates the Virtual Host configuration for the domain supplied in the command, the MySQL Database, the Database User, and the Database User Password.

  Example Command: (Creates a Wordpress site for example.com in /var/www/)    
  
  bash setup-debian.sh wordpress example.com

* Install Drupal 6 
  - Installs the latest version of Drupal 6. Then creates the Virtual Host configuration for the domain supplied in the command, the MySQL Database, the Database User, and the Database User Password..

  Example Command:  (Creates a Drupal 6 installation for example.com in /var/www/example.com)  
  
  bash setup-debian.sh drupal6 example.com
  
* Install Drupal 7 
  - Installs the latest version of Drupal 7. Then creates the Virtual Host configuration for the domain supplied in the command, the MySQL Database, the Database User, and the Database User Password..

  Example Command:  (Creates a Drupal 7 installation for example.com in /var/www/example.com)  
  
  bash setup-debian.sh drupal7 example.com

* Install Magento Community Ecommerce CMS
  - Installs the latest version of Magento Community, the best open source Ecommerce solution available today.
  
  Example Command: (Creates a Magento Community installation for example.com in /var/www/vhosts/magento/example.com)
  
  bash setup-debian.sh magento example.com

### SOFTWARE STACK
* Dropbear 
  - Replaces openssh. Invoked from xinetd.
* Inetutils-syslogd 
  - Replaces resyslog.
* Exim4 
  - Replaces sendmail (if installed). Re-configured to allow Internet delivery.
* Cron 
  - Schedule tasks on your server, similar to that of the task manager in Windows.
* Nginx 
  - Lightweight httpd replacement for Apache web server.
* MySQL 
  - Optimized with innodb and query caching removed with reduced key buffer size. 
* PHP 
  - Optimized PHP built with FastCGI and only running 1 child process which respawns ever 5,000 requests.