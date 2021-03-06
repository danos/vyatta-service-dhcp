#!/usr/bin/perl

# Module: dhcpdv6-show-status.pl
#
# **** License ****
# Copyright (c) 2019 AT&T Intellectual Property.  All rights reserved.
# Copyright (c) 2014-2015, Brocade Comunications Systems, Inc.
# All Rights Reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010-2013 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Author: Bob Gilligan
# Date: April 2010
# Description: Script to display status about DHCPv6 server
#
# **** End License ****

use strict;
use warnings;
use lib "/opt/vyatta/share/perl5/";

use Getopt::Long;
use Vyatta::Config;

#
# Main Section
#
my $rtinst;
my $config_prefix;

GetOptions(
    "rtinst=s"  =>  \$rtinst,
    );

if ( $rtinst eq "default" ) {
    $config_prefix = "service";
} else {
    $config_prefix = "routing routing-instance $rtinst service";
}


my $vcDHCP = new Vyatta::Config();

my $exists=$vcDHCP->existsOrig("$config_prefix dhcpv6-server");

my $configured_count=0;
if ($exists) {
    printf("DHCPv6 Server is configured in routing-instance $rtinst ");
    $configured_count++;
} else {
    printf("DHCPv6 Server is not configured in routing-instance $rtinst ");
}

my $ps_output=`ps -C dhcpd -o args --no-headers | grep $rtinst`;

my $running_count=0;

my @output = split(/\n/, $ps_output);

foreach my $line (@output) {
    if ($line =~ m/ -6 /) {
	$running_count++;
    }
}

if ($running_count == 0) {
    if ($configured_count == 0) {
	printf("and ");
    } else {
	printf("but ");
    }
    printf("is not running.\n");
} else {
    if ($configured_count == 0) {
	printf("but ");
    } else {
	printf("and ");
    }
    printf("is running.\n");
}

exit 0;

