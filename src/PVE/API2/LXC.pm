package PVE::API2::LXC;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param run_command);
use PVE::Exception qw(raise raise_param_exc);
use PVE::INotify;
use PVE::Cluster qw(cfs_read_file);
use PVE::AccessControl;
use PVE::Storage;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::LXC;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::RESTHandler);

use Data::Dumper; # fixme: remove

my $get_container_storage = sub {
    my ($stcfg, $vmid, $lxc_conf) = @_;

    my $path = $lxc_conf->{'lxc.rootfs'};
    my ($vtype, $volid) = PVE::Storage::path_to_volume_id($stcfg, $path);
    my ($sid, $volname) = PVE::Storage::parse_volume_id($volid, 1) if $volid;
    return wantarray ? ($sid, $volname, $path) : $sid;
};

my $check_ct_modify_config_perm = sub {
    my ($rpcenv, $authuser, $vmid, $pool, $key_list) = @_;
    
    return 1 if $authuser ne 'root@pam';

    foreach my $opt (@$key_list) {

	if ($opt eq 'cpus' || $opt eq 'cpuunits' || $opt eq 'cpulimit') {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.CPU']);
	} elsif ($opt eq 'disk') {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.Disk']);
	} elsif ($opt eq 'memory' || $opt eq 'swap') {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.Memory']);
	} elsif ($opt =~ m/^net\d+$/ || $opt eq 'nameserver' || 
		 $opt eq 'searchdomain' || $opt eq 'hostname') {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.Network']);
	} else {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.Options']);
	}
    }

    return 1;
};


__PACKAGE__->register_method({
    name => 'vmlist', 
    path => '', 
    method => 'GET',
    description => "LXC container index (per node).",
    permissions => {
	description => "Only list CTs where you have VM.Audit permissons on /vms/<vmid>.",
	user => 'all',
    },
    proxyto => 'node',
    protected => 1, # /proc files are only readable by root
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{vmid}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $vmstatus = PVE::LXC::vmstatus();

	my $res = [];
	foreach my $vmid (keys %$vmstatus) {
	    next if !$rpcenv->check($authuser, "/vms/$vmid", [ 'VM.Audit' ], 1);

	    my $data = $vmstatus->{$vmid};
	    $data->{vmid} = $vmid;
	    push @$res, $data;
	}

	return $res;
  
    }});

__PACKAGE__->register_method({
    name => 'create_vm', 
    path => '', 
    method => 'POST',
    description => "Create or restore a container.",
    permissions => {
	user => 'all', # check inside
 	description => "You need 'VM.Allocate' permissions on /vms/{vmid} or on the VM pool /pool/{pool}. " .
	    "For restore, it is enough if the user has 'VM.Backup' permission and the VM already exists. " .
	    "You also need 'Datastore.AllocateSpace' permissions on the storage.",
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
    	additionalProperties => 0,
	properties => PVE::LXC::json_config_properties({
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    ostemplate => {
		description => "The OS template or backup file.",
		type => 'string', 
		maxLength => 255,
	    },
	    password => { 
		optional => 1, 
		type => 'string',
		description => "Sets root password inside container.",
	    },
	    storage => get_standard_option('pve-storage-id', {
		description => "Target storage.",
		default => 'local',
		optional => 1,
	    }),
	    force => {
		optional => 1, 
		type => 'boolean',
		description => "Allow to overwrite existing container.",
	    },
	    restore => {
		optional => 1, 
		type => 'boolean',
		description => "Mark this as restore task.",
	    },
	    pool => { 
		optional => 1,
		type => 'string', format => 'pve-poolid',
		description => "Add the VM to the specified pool.",
	    },
	}),
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	my $basecfg_fn = PVE::LXC::config_file($vmid);

	my $same_container_exists = -f $basecfg_fn;

	my $restore = extract_param($param, 'restore');

	my $force = extract_param($param, 'force');

	if (!($same_container_exists && $restore && $force)) {
	    PVE::Cluster::check_vmid_unused($vmid);
	}
	
	my $password = extract_param($param, 'password');

	my $storage = extract_param($param, 'storage') || 'local';

	my $pool = extract_param($param, 'pool');
	
	my $storage_cfg = cfs_read_file("storage.cfg");

	my $scfg = PVE::Storage::storage_check_node($storage_cfg, $storage, $node);

	raise_param_exc({ storage => "storage '$storage' does not support container root directories"})
	    if !$scfg->{content}->{rootdir};

	my $private = PVE::Storage::get_private_dir($storage_cfg, $storage, $vmid);

	if (defined($pool)) {
	    $rpcenv->check_pool_exist($pool);
	    $rpcenv->check_perm_modify($authuser, "/pool/$pool");
	} 

	if ($rpcenv->check($authuser, "/vms/$vmid", ['VM.Allocate'], 1)) {
	    # OK
	} elsif ($pool && $rpcenv->check($authuser, "/pool/$pool", ['VM.Allocate'], 1)) {
	    # OK
	} elsif ($restore && $force && $same_container_exists &&
		 $rpcenv->check($authuser, "/vms/$vmid", ['VM.Backup'], 1)) {
	    # OK: user has VM.Backup permissions, and want to restore an existing VM
	} else {
	    raise_perm_exc();
	}

	&$check_ct_modify_config_perm($rpcenv, $authuser, $vmid, $pool, [ keys %$param]);

	PVE::Storage::activate_storage($storage_cfg, $storage);

	my $ostemplate = extract_param($param, 'ostemplate');
	
	my $archive;

	if ($ostemplate eq '-') {
	    die "archive pipe not implemented\n" 
	    # $archive = '-';
	} else {
	    $rpcenv->check_volume_access($authuser, $storage_cfg, $vmid, $ostemplate);
	    $archive = PVE::Storage::abs_filesystem_path($storage_cfg, $ostemplate);
	}

	my $memory = $param->{memory} || 512;
	my $hostname = $param->{hostname} || "T$vmid";
	my $conf = {};
	
	$conf->{'lxc.utsname'} = $param->{hostname} || "CT$vmid";
	$conf->{'lxc.cgroup.memory.limit_in_bytes'} = "${memory}M";

	my $code = sub {
	    my $temp_conf_fn = PVE::LXC::write_temp_config($vmid, $conf);

	    my $cmd = ['lxc-create', '-f', $temp_conf_fn, '-t', 'pve', '-n', $vmid,
		       '--', '--archive', $archive];

	    eval { PVE::Tools::run_command($cmd); };
	    my $err = $@;

	    unlink $temp_conf_fn;

	    die $err if $err;
	};
	
	my $realcmd = sub { PVE::LXC::lock_container($vmid, 1, $code); };

	return $rpcenv->fork_worker($param->{restore} ? 'vzrestore' : 'vzcreate', 
				    $vmid, $authuser, $realcmd);
 	    
    }});

my $vm_config_perm_list = [
	    'VM.Config.Disk', 
	    'VM.Config.CPU', 
	    'VM.Config.Memory', 
	    'VM.Config.Network', 
	    'VM.Config.Options',
    ];

__PACKAGE__->register_method({
    name => 'update_vm', 
    path => '{vmid}/config', 
    method => 'PUT',
    protected => 1,
    proxyto => 'node',
    description => "Set container options.",
    permissions => {
	check => ['perm', '/vms/{vmid}', $vm_config_perm_list, any => 1],
    },
    parameters => {
    	additionalProperties => 0,
	properties => PVE::LXC::json_config_properties(
	    {
		node => get_standard_option('pve-node'),
		vmid => get_standard_option('pve-vmid'),
		delete => {
		    type => 'string', format => 'pve-configid-list',
		    description => "A list of settings you want to delete.",
		    optional => 1,
		},
		digest => {
		    type => 'string',
		    description => 'Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.',
		    maxLength => 40,
		    optional => 1,		    
		}
	    }),
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	my $digest = extract_param($param, 'digest');

	die "no options specified\n" if !scalar(keys %$param);

	my $delete_str = extract_param($param, 'delete');
	my @delete = PVE::Tools::split_list($delete_str);
	
	&$check_ct_modify_config_perm($rpcenv, $authuser, $vmid, undef, [@delete]);
	
	foreach my $opt (@delete) {
	    raise_param_exc({ delete => "you can't use '-$opt' and " .
				  "-delete $opt' at the same time" })
		if defined($param->{$opt});
	    
	    if (!PVE::LXC::option_exists($opt)) {
		raise_param_exc({ delete => "unknown option '$opt'" });
	    }
	}

	&$check_ct_modify_config_perm($rpcenv, $authuser, $vmid, undef, [keys %$param]);

	my $code = sub {

	    my $conf = PVE::LXC::load_config($vmid);

	    PVE::Tools::assert_if_modified($digest, $conf->{digest});

	    # die if running

	    foreach my $opt (@delete) {
		if ($opt eq 'hostname') {
		    die "unable to delete required option '$opt'\n";
		} elsif ($opt =~ m/^net\d$/) {
		    delete $conf->{$opt};
		} else {
		    die "implement me"
		}
	    }

	    foreach my $opt (keys %$param) {
		my $value = $param->{$opt};
		if ($opt eq 'hostname') {
		    $conf->{'lxc.utsname'} = $value;
		} if ($opt =~ m/^net(\d+)$/) {
		    my $netid = $1;
		    my $net = PVE::LXC::parse_lxc_network($value);
		    $net->{'veth.pair'} = "veth${vmid}.$netid";
		    $conf->{$opt} = $net;
		} else {
		    die "implement me"
		}
	    }

	    PVE::LXC::write_config($vmid, $conf);
	};

	PVE::LXC::lock_container($vmid, undef, $code);

	return undef;
    }});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Firewall::CT",  
    path => '{vmid}/firewall',
});

__PACKAGE__->register_method({
    name => 'vmdiridx',
    path => '{vmid}', 
    method => 'GET',
    proxyto => 'node',
    description => "Directory index",
    permissions => {
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		subdir => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{subdir}" } ],
    },
    code => sub {
	my ($param) = @_;

	# test if VM exists
	my $conf = PVE::LXC::load_config($param->{vmid});

	my $res = [
	    { subdir => 'config' },
#	    { subdir => 'status' },
#	    { subdir => 'vncproxy' },
#	    { subdir => 'spiceproxy' },
#	    { subdir => 'migrate' },
#	    { subdir => 'initlog' },
	    { subdir => 'rrd' },
	    { subdir => 'rrddata' },
	    { subdir => 'firewall' },
	    ];
	
	return $res;
    }});

__PACKAGE__->register_method({
    name => 'rrd', 
    path => '{vmid}/rrd', 
    method => 'GET',
    protected => 1, # fixme: can we avoid that?
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    description => "Read VM RRD statistics (returns PNG)",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    timeframe => {
		description => "Specify the time frame you are interested in.",
		type => 'string',
		enum => [ 'hour', 'day', 'week', 'month', 'year' ],
	    },
	    ds => {
		description => "The list of datasources you want to display.",
 		type => 'string', format => 'pve-configid-list',
	    },
	    cf => {
		description => "The RRD consolidation function",
 		type => 'string',
		enum => [ 'AVERAGE', 'MAX' ],
		optional => 1,
	    },
	},
    },
    returns => {
	type => "object",
	properties => {
	    filename => { type => 'string' },
	},
    },
    code => sub {
	my ($param) = @_;

	return PVE::Cluster::create_rrd_graph(
	    "pve2-vm/$param->{vmid}", $param->{timeframe}, 
	    $param->{ds}, $param->{cf});
					      
    }});

__PACKAGE__->register_method({
    name => 'rrddata', 
    path => '{vmid}/rrddata', 
    method => 'GET',
    protected => 1, # fixme: can we avoid that?
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    description => "Read VM RRD statistics",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    timeframe => {
		description => "Specify the time frame you are interested in.",
		type => 'string',
		enum => [ 'hour', 'day', 'week', 'month', 'year' ],
	    },
	    cf => {
		description => "The RRD consolidation function",
 		type => 'string',
		enum => [ 'AVERAGE', 'MAX' ],
		optional => 1,
	    },
	},
    },
    returns => {
	type => "array",
	items => {
	    type => "object",
	    properties => {},
	},
    },
    code => sub {
	my ($param) = @_;

	return PVE::Cluster::create_rrd_data(
	    "pve2-vm/$param->{vmid}", $param->{timeframe}, $param->{cf});
    }});


__PACKAGE__->register_method({
    name => 'vm_config', 
    path => '{vmid}/config', 
    method => 'GET',
    proxyto => 'node',
    description => "Get container configuration.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { 
	type => "object",
	properties => {
	    digest => {
		type => 'string',
		description => 'SHA1 digest of configuration file. This can be used to prevent concurrent modifications.',
	    }
	},
    },
    code => sub {
	my ($param) = @_;

	my $lxc_conf = PVE::LXC::load_config($param->{vmid});

	# NOTE: we only return selected/converted values
	
	my $conf = { digest => $lxc_conf->{digest} };

	my $stcfg = PVE::Cluster::cfs_read_file("storage.cfg");

	my ($sid, undef, $path) = &$get_container_storage($stcfg, $param->{vmid}, $lxc_conf);
	$conf->{storage} = $sid || $path;

	my $properties = PVE::LXC::json_config_properties();

	foreach my $k (keys %$properties) {

	    if ($k eq 'description') {
		if (my $raw = $lxc_conf->{'pve.comment'}) {
		    $conf->{$k} = PVE::Tools::decode_text($raw);
		}
	    } elsif ($k eq 'hostname') {
		$conf->{$k} = $lxc_conf->{'lxc.utsname'} if $lxc_conf->{'lxc.utsname'};
	    } elsif ($k =~ m/^net\d$/) {
		my $net = $lxc_conf->{$k};
		next if !$net;
		$conf->{$k} = PVE::LXC::print_lxc_network($net);
	    }
	}

	return $conf;
    }});

__PACKAGE__->register_method({
    name => 'destroy_vm', 
    path => '{vmid}', 
    method => 'DELETE',
    protected => 1,
    proxyto => 'node',
    description => "Destroy the container (also delete all uses files).",
    permissions => {
	check => [ 'perm', '/vms/{vmid}', ['VM.Allocate']],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $vmid = $param->{vmid};

	# test if container exists
	my $conf = PVE::LXC::load_config($param->{vmid});

	my $realcmd = sub {
	    my $cmd = ['lxc-destroy', '-n', $vmid ];

	    run_command($cmd);

	    PVE::AccessControl::remove_vm_from_pool($vmid);
	};

	return $rpcenv->fork_worker('vzdestroy', $vmid, $authuser, $realcmd);
    }});

1;
