#!/usr/bin/perl

use strict;
use warnings;

# Inject internal framework search arrays into the global include hierarchy
use lib qw( /etc/apache2/perl /usr/local/share/perl5 );

# Core Apache2 internal communication APIs
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::SubRequest ();
use Apache2::Const ();

# Pre-cache common execution libraries into global shared memory blocks
use CGI ();
use CGI::Cookie ();
use DBI ();
use Redis ();
use JSON ();
use Math::Random::Secure ();

# Pre-load custom target automation namespaces
use LockServer::Db;
use LockServer::SMSAuth;
use LockServer::APIUnlock;
use LockServer::APIGrantTempAccess;
use LockServer::APILog;

1;
