Apache Logging for Clusters
===========================

A Painful History
-----------------

Apache logging in a clustered environment is pain.  Apache's built-in
access logging assumes a single log file per ``VirtualHost`` written to by
a single server.  There is a syslog option for error logs, but it makes no
attempt to break out the error logs per ``VirtualHost``.

Our requirements are simple:

1. Reliable logging from multiple hosts.
2. Easy access to real-time logs for developers.
3. Minimal infrastructure required.
4. Scale to many hundreds of VirtualHosts.
   
Over the years I've explored a number of techniques for providing useful
real-time logs in a single location from multiple web servers:

1. Pointing all the servers at the same log file on the NFS server.
   Unfortunately Apache doesn't lock log files prior to each write, so log
   lines get munged together.

2. Assigning a unique log file to each host/virtualhost combination,
   sorting them back together each night.  This worked, but the developers
   hated it::

     logs/www.example.com/error_log.node01
     logs/www.example.com/error_log.node02
     logs/www.example.com/error_log.node03
     ...
     logs/www.example.com/access_log.node01
     logs/www.example.com/access_log.node02
     logs/www.example.com/access_log.node03
     ...

3. The only packaged solution I've seen is `mod_log_spread`_ which,
   in 2000 when I first started looking, seemed overly complex for my
   needs.  Now in 2010, its ChangeLog only shows one change since 2006.
   Overly complex + abandonware?  No thanks.

4. My predecessor at Clockwork elected to use syslog, injecting the
   messages by piping them through ``/bin/logger``, like so::

    <VirtualHost *:80>
        SiteName www.example.com
        DocumentRoot /www/e/www.example.com/htdocs/
        CustomLog "| /bin/logger -p local0.notice -t www.example.com" combined
        ErrorLog "| /bin/logger -p local1.notice -t www.example.com"
    </VirtualHost>

   Combine this with an log destination in the `syslog-ng`_ config that
   describes the file like this::

     file("/www/logs/$PROGRAM/error_log")

   This worked quite well.  As a bonus, syslog-ng would automatically
   create log directories for each new site the first time a log entry
   was generated.

   Unfortunately this approach scales poorly.  Every ``VirtualHost``
   spawns two instances each of ``/bin/sh`` and ``/bin/logger``.  At one
   point we had more than 15,000 copies of ``/bin/logger`` running on our
   cluster.  As you can imagine, this made restarting Apache a bit of a
   pain, not to mention the resource and scheduler overhead.

A New Hope
----------

We've come up with a solution that's been working very well for us for
close to six months.

Features:

* Works for both access and error logs, albeit slightly differently.
* Uses syslog as transport.
* Minimal system impact. 

Access Logs
~~~~~~~~~~~

Access logs are the easy part.  Balabit (authors of syslog-ng)
`described`_ how to customize the Apache access log format, completely
emulating the syslog header format.  These logs are sent to a FIFO which
syslog-ng reads.

::

    ## /etc/apache2/conf.d/log2syslog

    LogFormat "<142>%{%b %e %H:%M:%S}t discard %v: %h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" %D" syslogformat

This is the magic bit: ``"<142>%{%b %e %H:%M:%S}t discard %v:``.

The number in the angle brackets is the combined priority and facility,
calculated by by the method described in `RFC 5424`_.  In this case, we're
using local1:info.

The next section, ``%{%b %e %H:%M:%S}t``, creates a time stamp in a format
acceptable to syslog.

The string "``discard``" would normally be the hostname of the source of
the syslog message, but it is not needed in this case.

And "``%v``" is the ``ServerName`` of the ``VirtualHost`` that generated
the message.  It is being used to populate the "program" field in the
syslog message.

::

    ## Excerpted from /etc/syslog-ng.conf on webhost

    source s_apache_access {
        pipe("/var/spool/apache2/access_log");
    };

This tells syslog-ng to read from the pipe.

::

    ## Excerpted from /etc/syslog-ng.conf on loghost

    destination df_apache_access_log {
        file("/var/log/www/$PROGRAM/access_log"
             template("$MSGONLY $HOST\n")
             template_escape(no) );
    };

    filter f_apache_access_log { facility(local1); };

    log {
        source(s_all);
        filter(f_apache_access_log);
        destination(df_apache_access_log);
    };

The ``$PROGRAM`` field (populated by "``%v``" in the original log message)
is used to tell syslog-ng where to store the access log.  If the directory
doesn't exist, syslog-ng will automatically create it.

Error Logs
~~~~~~~~~~

Error logs are more complex.  Since the error log format is not
customizable in the same way as access logs, it's not possible to inject
information about the VirtualHost that triggered the error directly into
the log message.

We solved this problem by creating a unique FIFO for each VirtualHost.
Monitoring these FIFOs is a custom daemon (errorlog2syslog, written in
Python) that reads the error log messages and injects them into syslog.
Since the daemon knows which FIFO it read the message from, it is able to
populate the "program" field accordingly. 

The syslog-ng config on the web host does not require customization, as
the log messages are injected by the daemon.

The daemon that runs on each web host is fairly straightforward:

1. On startup it scans the FIFO directory and registers any FIFOs it finds
   there with poll().
2. It spawns a thread that watches the FIFO directory via `inotify`_ so it
   will be informed of any new FIFOs added later.
3. When new log entries are signalled by poll(), it injects the message
   into syslog.

It is very important that this daemon not crash, as Apache will block if
the writes to the error FIFOs block.  Within a few seconds Apache will
hit stop working entirely.  Fortunately it unblocks itself nicely as soon as
something starts reading from the FIFOs again.  For this reason, we have
`upstart`_ configured to respawn the daemon if it exits.

The configuration on the loghost is nearly identical to the access log
directive shown above::

    ## Excerpted from /etc/syslog-ng.conf on loghost

    destination df_apache_error_log {
        file("/var/log/www/$PROGRAM/error_log"
             template("$MSGONLY $HOST\n")
             template_escape(no) );
    };

    filter f_apache_error_log { facility(local2); };

    log {
        source(s_all);
        filter(f_apache_error_log);
        destination(df_apache_error_log);
    };

We also wrote a custom wrapper for ``apache2ctl`` to generate the FIFOs.
By wrapping ``apache2ctl``, we can be confident that the normal system init
scripts will always call my code first.  Otherwise Apache will create all
of the error logs as plain files.

On Debian, it's straightforward to guarantee that Apache upgrades do not
blow away the wrapper script::

  dpkg-divert --add --rename --divert /usr/sbin/apache2ctl.distrib /usr/sbin/apache2ctl

When the divert in place, Apache upgrades will always write new versions
of ``apache2ctl`` to ``/usr/sbin/apache2ctl.distrib``, leaving the wrapper
in place.  The deb package does this automatically in the ``preinst``
script.

Summary
-------

Access logs are injected directly into syslog via FIFO using a custom
Apache LogFormat directive.

Error logs are delivered via FIFO to a custom daemon that adds additional
data and injects the messages into syslog.

The macro capabilities of syslog-ng allow us to add and remove websites
without modifying the syslog-ng config.

This system has been running in our production web cluster for about six
months.  The only issue we've seen is sometimes ``errorlog2syslog`` not
starting successfully after a reboot.  A quick ``start
cw_errorlog2syslog`` and traffic starts flowing again.  To the best of our
knowledge, it has never died after reboot.  If it has, `upstart`_
prevented us from noticing the downtime.

Typical log volume at our site is 2,000,000 / day for the access logs and
100,000 for error logs.  We have seen error log spikes up to 900,000
without any problems or increased load from ``errorlog2syslog``.

.. _mod_log_spread: http://www.backhand.org/mod_log_spread/
.. _syslog-ng: http://www.balabit.com/network-security/syslog-ng
.. _RFC 5424: http://tools.ietf.org/html/rfc5424#section-6.2.1
.. _described: http://peter.blogs.balabit.com/2010/02/how-to-collect-apache-logs-by-syslog-ng/
.. _inotify: http://en.wikipedia.org/wiki/Inotify
.. _upstart: http://upstart.ubuntu.com/
