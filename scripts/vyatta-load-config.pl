#!/usr/bin/perl

# Author: An-Cheng Huang <ancheng@vyatta.com.
# Date: 2007
# Description: Perl script for loading config file at run time.

# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2006, 2007, 2008 Vyatta, Inc.
# All Rights Reserved.
# **** End License ****

# $0: config file.

use strict;
use lib "/opt/vyatta/share/perl5/";
use POSIX;
use IO::Prompt;
use Sys::Syslog qw(:standard :macros);
use VyattaConfigLoad;

my $etcdir = $ENV{vyatta_sysconfdir};
my $sbindir = $ENV{vyatta_sbindir};
my $bootpath = $etcdir . "/config";
my $load_file = $bootpath . "/config.boot";
my $url_tmp_file = $bootpath . "/config.boot.$$";

if ($#ARGV > 0) {
  print "Usage: load <config_file_name>\n";
  exit 1;
}

my $mode = 'local';
my $proto;

if (defined($ARGV[0])) {
  $load_file = $ARGV[0];
}
my $orig_load_file = $load_file;

if ($load_file =~ /^[^\/]\w+:\//) {
  if ($load_file =~ /^(\w+):\/\/\w/) {
    $mode = 'url';
    $proto = lc($1);
    if ($proto eq 'tftp') {
    } elsif ($proto eq 'ftp') {
    } elsif ($proto eq 'http') {
    } elsif ($proto eq 'scp') {
    } else {
      print "Invalid url protocol [$proto]\n";
      exit 1;
    }
  } else {
    print "Invalid url [$load_file]\n";
    exit 1;
  }
}

if ($mode eq 'local' and !($load_file =~ /^\//)) {
  # relative path
  $load_file = "$bootpath/$load_file";
}

if ($mode eq 'local') {
  if (!open(CFG, "<$load_file")) {
    print "Cannot open configuration file $load_file\n";
    exit 1;
  }
} elsif ($mode eq 'url') {
  if (! -f '/usr/bin/curl') {
    print "Package [curl] not installed\n";
    exit 1;
  }
  if ($proto eq 'http') {
    #
    # error codes are send back in html, so 1st try a header
    # and look for "HTTP/1.1 200 OK"
    #
    my $rc = `curl -q -I $load_file 2>&1`;
    if ($rc =~ /HTTP\/\d+\.?\d\s+(\d+)\s+(.*)$/mi) {
      my $rc_code   = $1;
      my $rc_string = $2;
      if ($rc_code == 200) {
	# good resonse
      } else {
	print "http error: [$rc_code] $rc_string\n";
        exit 1;
      }
    } else {
      print "Error: $rc\n";
      exit 1;
    }
  }
  my $rc = system("curl -# -o $url_tmp_file $load_file");
  if ($rc) {
      print "Can not open remote configuration file $load_file\n";
      exit 1;
  }
  if (!open(CFG, "<$url_tmp_file")) {  
    print "Cannot open configuration file $load_file\n";
    exit 1;
  }
  $load_file = $url_tmp_file;
}

my $xorp_cfg  = 0;
my $valid_cfg = 0;
while (<CFG>) {
  if (/\/\*XORP Configuration File, v1.0\*\//) {
    $xorp_cfg = 1;
    last;
  } elsif (/vyatta-config-version/) {
    $valid_cfg = 1;
    last;
  }
}
if ($xorp_cfg or ! $valid_cfg) {
  if ($xorp_cfg) {
    print "Warning: Loading a pre-Glendale configuration.\n";
  } else {
    print "Warning: file does NOT appear to be a valid config file.\n";
  }
  if (!prompt("Do you want to continue? ", -tty, -Yes, -default=>'no')) {
    print "Configuration not loaded\n";
    exit 1;
  }
}
close CFG;

# log it
openlog($0, "", LOG_USER);
my $login = getlogin() || getpwuid($<) || "unknown";
syslog("warning", "Load config [$orig_load_file] by $login");

# do config migration
system("$sbindir/vyatta_config_migrate.pl $load_file");

print "Loading config file $load_file...\n";
my %cfg_hier = VyattaConfigLoad::loadConfigHierarchy($load_file);
if (scalar(keys %cfg_hier) == 0) {
  print "The specified file does not contain any configuration.\n";
  print "Do you want to remove everything in the running configuration? [no] ";
  my $resp = <STDIN>;
  if (!($resp =~ /^yes$/i)) {
    print "Configuration not loaded\n";
    exit 1;
  }
}

my %cfg_diff = VyattaConfigLoad::getConfigDiff(\%cfg_hier);

my @delete_list = @{$cfg_diff{'delete'}};
my @set_list = @{$cfg_diff{'set'}};

foreach (@delete_list) {
  my ($cmd_ref, $rank) = @{$_};
  my @cmd = ( "$sbindir/my_delete", @{$cmd_ref} );
  my $cmd_str = join ' ', @cmd;
  system("$cmd_str");
  if ($? >> 8) {
    $cmd_str =~ s/^$sbindir\/my_//;
    print "\"$cmd_str\" failed\n";
  }
}

foreach (@set_list) {
  my ($cmd_ref, $rank) = @{$_};
  my @cmd = ( "$sbindir/my_set", @{$cmd_ref} );
  my $cmd_str = join ' ', @cmd;
  system("$cmd_str");
  if ($? >> 8) {
    $cmd_str =~ s/^$sbindir\/my_//;
    print "\"$cmd_str\" failed\n";
  }
}

system("$sbindir/my_commit");
if ($? >> 8) {
  print "Load failed (commit failed)\n";
  exit 1;
}

print "Done\n";
exit 0;
