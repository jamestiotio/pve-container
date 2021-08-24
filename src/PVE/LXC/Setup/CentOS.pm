package PVE::LXC::Setup::CentOS;

use strict;
use warnings;

use PVE::Tools;
use PVE::Network;
use PVE::LXC;

use PVE::LXC::Setup::Base;

use base qw(PVE::LXC::Setup::Base);

sub new {
    my ($class, $conf, $rootdir) = @_;

    my $release = PVE::Tools::file_read_firstline("$rootdir/etc/redhat-release");
    die "unable to read version info\n" if !defined($release);

    my $version;

    if (($release =~ m/release\s+(\d+\.\d+)(\.\d+)?/) || ($release =~ m/release\s+(\d+)/)) {
	if ($1 >= 5 && $1 <= 9) {
	    $version = $1;
	}
    }

    die "unsupported centos release '$release'\n" if !$version;

    my $self = { conf => $conf, rootdir => $rootdir, version => $version };

    $conf->{ostype} = "centos";

    return bless $self, $class;
}

my $tty_conf = <<__EOD__;
# tty - getty
#
# This service maintains a getty on the specified device.
#
# Do not edit this file directly. If you want to change the behaviour,
# please create a file tty.override and put your changes there.

stop on runlevel [S016]

respawn
instance \$TTY
exec /sbin/mingetty --nohangup \$TTY
usage 'tty TTY=/dev/ttyX  - where X is console id'
__EOD__
    
my $start_ttys_conf = <<__EOD__;
#
# This service starts the configured number of gettys.
#
# Do not edit this file directly. If you want to change the behaviour,
# please create a file start-ttys.override and put your changes there.

start on stopped rc RUNLEVEL=[2345]

env ACTIVE_CONSOLES=/dev/tty[1-6]
env X_TTY=/dev/tty1
task
script
        . /etc/sysconfig/init
        for tty in \$(echo \$ACTIVE_CONSOLES) ; do
                [ "\$RUNLEVEL" = "5" -a "\$tty" = "\$X_TTY" ] && continue
                initctl start tty TTY=\$tty
        done
end script
__EOD__

my $power_status_changed_conf = <<__EOD__;
#  power-status-changed - shutdown on SIGPWR
#
start on power-status-changed
    
exec /sbin/shutdown -h now "SIGPWR received"
__EOD__

sub template_fixup {
    my ($self, $conf) = @_;

    if ($self->{version} < 7) {
	# re-create emissing files for tty

	$self->ct_make_path('/etc/init');

	my $filename = "/etc/init/tty.conf";
	if ($self->ct_file_exists($filename)) {
	    my $data = $self->ct_file_get_contents($filename);
	    $data =~ s|^(exec /sbin/mingetty)(?!.*--nohangup) (.*)$|$1 --nohangup $2|gm;
	    $self->ct_file_set_contents($filename, $data);
	} else {
	    $self->ct_file_set_contents($filename, $tty_conf);
	}

	$filename = "/etc/init/start-ttys.conf";
	$self->ct_file_set_contents($filename, $start_ttys_conf)
	    if ! $self->ct_file_exists($filename);

	$filename = "/etc/init/power-status-changed.conf";
	$self->ct_file_set_contents($filename, $power_status_changed_conf)
	    if ! $self->ct_file_exists($filename);

	# do not start udevd
	$filename = "/etc/rc.d/rc.sysinit";
	my $data = $self->ct_file_get_contents($filename);
	$data =~ s!^(/sbin/start_udev.*)$!#$1!gm;
	$self->ct_file_set_contents($filename, $data);
    }

    # temporary fix for systemd-firstboot
    my $locale_conf = '/etc/locale.conf';
    $self->ct_file_set_contents($locale_conf, "LANG=C.utf8") if !$self->ct_file_exists($locale_conf);

    # always call so root can login, if /etc/securetty doesn't exists it's a no-op
    $self->setup_securetty($conf);
}

sub setup_init {
    my ($self, $conf) = @_;

     # edit/etc/securetty

    $self->fixup_old_getty();

    $self->setup_container_getty_service($conf);
}

sub set_hostname {
    my ($self, $conf) = @_;

    # Redhat wants the fqdn in /etc/sysconfig/network's HOSTNAME
    my $hostname = $conf->{hostname} || 'localhost';

    my $hostname_fn = "/etc/hostname";
    my $sysconfig_network = "/etc/sysconfig/network";

    my $oldname;
    if ($self->ct_file_exists($hostname_fn)) {
	$oldname = $self->ct_file_read_firstline($hostname_fn) || 'localhost';
    } else {
	my $data = $self->ct_file_get_contents($sysconfig_network);
	if ($data =~ m/^HOSTNAME=\s*(\S+)\s*$/m) {
	    $oldname = $1;
	}
    }

    my ($ipv4, $ipv6) = PVE::LXC::get_primary_ips($conf);
    my $hostip = $ipv4 || $ipv6;

    my ($searchdomains) = $self->lookup_dns_conf($conf);

    $self->update_etc_hosts($hostip, $oldname, $hostname, $searchdomains);

    if ($self->ct_file_exists($hostname_fn)) {
	$self->ct_file_set_contents($hostname_fn, "$hostname\n");
    }

    if ($self->ct_file_exists($sysconfig_network)) {
	my $data = $self->ct_file_get_contents($sysconfig_network);
	if ($data !~ s/^HOSTNAME=\h*(\S+)\h*$/HOSTNAME=$hostname/m) {
	    $data .= "HOSTNAME=$hostname\n";
	}
	$self->ct_file_set_contents($sysconfig_network, $data);
    }
}

sub setup_network {
    my ($self, $conf) = @_;

    my ($gw, $gw6);

    $self->ct_make_path('/etc/sysconfig/network-scripts');

    my ($has_ipv4, $has_ipv6);

    foreach my $k (keys %$conf) {
	next if $k !~ m/^net(\d+)$/;
	my $d = PVE::LXC::Config->parse_lxc_network($conf->{$k});
	next if !$d->{name};
	$has_ipv4 = 1 if defined($d->{ip});
	$has_ipv6 = 1 if defined($d->{ip6});

	my $filename = "/etc/sysconfig/network-scripts/ifcfg-$d->{name}";
	my $routefile = "/etc/sysconfig/network-scripts/route-$d->{name}";
	my $route6file = "/etc/sysconfig/network-scripts/route6-$d->{name}";
	my $routes = '';
	my $routes6 = '';

	my $header = "DEVICE=$d->{name}\nONBOOT=yes\n";
	my $data = '';
	my $bootproto = '';

	if ($d->{ip} && $d->{ip} ne 'manual') {
	    if ($d->{ip} eq 'dhcp') {
		$bootproto = 'dhcp';
	    } else {
		$bootproto = 'none';
		my $ipinfo = PVE::LXC::parse_ipv4_cidr($d->{ip});
		$data .= "IPADDR=$ipinfo->{address}\n";
		$data .= "NETMASK=$ipinfo->{netmask}\n";
		if (defined($d->{gw})) {
		    $data .= "GATEWAY=$d->{gw}\n";
		    if (!PVE::Network::is_ip_in_cidr($d->{gw}, $d->{ip}, 4)) {
			$routes .= "$d->{gw} dev $d->{name}\n";
			$routes .= "default via $d->{gw} dev $d->{name}\n";
		    }
		}
	    }
	}

	if ($d->{ip6} && $d->{ip6} ne 'manual') {
	    $bootproto = 'none' if !$bootproto;
	    $data .= "IPV6INIT=yes\n";
	    if ($d->{ip6} eq 'auto') {
		$data .= "IPV6_AUTOCONF=yes\n";
	    }
	    if ($d->{ip6} eq 'dhcp') {
		$data .= "DHCPV6C=yes\n";
	    } else {
		$data .= "IPV6ADDR=$d->{ip6}\n";
		if (defined($d->{gw6})) {
		    if (!PVE::Network::is_ip_in_cidr($d->{gw6}, $d->{ip6}, 6) &&
			!PVE::Network::is_ip_in_cidr($d->{gw6}, 'fe80::/10', 6)) {
			$routes6 .= "$d->{gw6} dev $d->{name}\n";
			$routes6 .= "default via $d->{gw6} dev $d->{name}\n";
		    } else {
			$data .= "IPV6_DEFAULTGW=$d->{gw6}\n";
		    }
		}
	    }
	}

	next unless $data || $bootproto;
	$header .= "BOOTPROTO=$bootproto\n";
	$self->ct_file_set_contents($filename, $header . $data);
	$self->ct_modify_file($routefile, $routes, delete => 1, prepend => 1);
	$self->ct_modify_file($route6file, $routes6, delete => 1, prepend => 1);
    }

    my $sysconfig_network = "/etc/sysconfig/network";
    if ($self->ct_file_exists($sysconfig_network)) {
	my $data = $self->ct_file_get_contents($sysconfig_network);
	if ($has_ipv4) {
	    if ($data !~ s/(NETWORKING)=\S+/$1=yes/) {
		$data .= "NETWORKING=yes\n";
	    }
	}
	if ($has_ipv6) {
	    if ($data !~ s/(NETWORKING_IPV6)=\S+/$1=yes/) {
		$data .= "NETWORKING_IPV6=yes\n";
	    }
	}
	$self->ct_file_set_contents($sysconfig_network, $data);
    }
}

1;
