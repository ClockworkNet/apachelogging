#!/bin/sh
# 
# Create pipe needed for syslog-ng to start.

if ! [ -d /var/run/apache2 ]; then
	mkdir -m 0755 /var/run/apache2/
fi

mkfifo -m 0644 /var/run/apache2/accesslog_pipe
chown www-data:www-data /var/run/apache2/accesslog_pipe
