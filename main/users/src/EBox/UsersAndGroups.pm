# Copyright (C) 2008-2012 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package EBox::UsersAndGroups;

use strict;
use warnings;

use base qw(EBox::Module::Service
            EBox::LdapModule
            EBox::Model::ModelProvider
            EBox::Model::CompositeProvider
            EBox::UserCorner::Provider
            EBox::UsersAndGroups::SyncProvider
          );

use EBox::Global;
use EBox::Util::Random;
use EBox::Ldap;
use EBox::Gettext;
use EBox::Menu::Folder;
use EBox::Menu::Item;
use EBox::Sudo;
use EBox::FileSystem;
use EBox::LdapUserImplementation;
use EBox::Config;
use EBox::UsersAndGroups::User;
use EBox::UsersAndGroups::Group;
use EBox::UsersAndGroups::OU;
use EBox::UsersSync::Master;
use EBox::UsersSync::Slave;

use Digest::SHA1;
use Digest::MD5;
use Crypt::SmbHash;
use Sys::Hostname;

use Error qw(:try);
use File::Copy;
use File::Slurp;
use File::Temp qw/tempfile/;
use Perl6::Junction qw(any);
use String::ShellQuote;
use Fcntl qw(:flock);

use constant USERSDN        => 'ou=Users';
use constant GROUPSDN       => 'ou=Groups';
use constant LIBNSSLDAPFILE => '/etc/ldap.conf';
use constant SECRETFILE     => '/etc/ldap.secret';
use constant DEFAULTGROUP   => '__USERS__';
use constant CA_DIR         => EBox::Config::conf() . 'ssl-ca/';
use constant SSL_DIR        => EBox::Config::conf() . 'ssl/';
use constant JOURNAL_DIR    => EBox::Config::home() . 'syncjournal/';
use constant CERT           => SSL_DIR . 'master.cert';
use constant AUTHCONFIGTMPL => '/etc/auth-client-config/profile.d/acc-ebox';

use constant LDAP_CONFDIR    => '/etc/ldap/slapd.d/';
use constant LDAP_DATADIR    => '/var/lib/ldap/';
use constant LDAP_USER     => 'openldap';
use constant LDAP_GROUP    => 'openldap';

sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(name => 'users',
                                      printableName => __n('Users and Groups'),
                                      @_);
    bless($self, $class);
    return $self;
}

# Method: actions
#
#       Override EBox::ServiceModule::ServiceInterface::actions
#
sub actions
{
    my ($self) = @_;

    my @actions;

    push(@actions,
            {
            'action' => __('Your LDAP database will be populated with some basic organizational units'),
            'reason' => __('Zentyal needs this organizational units to add users and groups into them.'),
            'module' => 'users'
            },
        );

    # FIXME: This probably won't work if PAM is enabled after enabling the module
    if ($self->model('PAM')->enable_pamValue()) {
        push(@actions,
                {
                 'action' => __('Configure PAM.'),
                 'reason' => __('Zentyal will give LDAP users system account.'),
                 'module' => 'users'
                }
        );
    }
    return \@actions;
}

# Method: usedFiles
#
#       Override EBox::Module::Service::files
#
sub usedFiles
{
    my ($self) = @_;
    my @files = ();

    push(@files,
        {
            'file' => '/etc/nsswitch.conf',
            'reason' => __('To make NSS use LDAP resolution for user and '.
                'group accounts. Needed for Samba PDC configuration.'),
            'module' => 'users'
        },
        {
            'file' => LIBNSSLDAPFILE,
            'reason' => __('To let NSS know how to access LDAP accounts.'),
            'module' => 'users'
        },
        {
            'file' => '/etc/fstab',
            'reason' => __('To add quota support to /home partition.'),
            'module' => 'users'
        },
        {
            'file' => '/etc/default/slapd',
            'reason' => __('To make LDAP listen on TCP and Unix sockets.'),
            'module' => 'users'
        },
        {
            'file' => SECRETFILE,
            'reason' => __('To copy LDAP admin password generated by ' .
                'Zentyal and allow other modules to access LDAP.'),
            'module' => 'users'
        },
    );

    return \@files;
}

# Method: initialSetup
#
# Overrides:
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    # Create default rules and services
    # only if installing the first time
    unless ($version) {
        my $fw = EBox::Global->modInstance('firewall');

        $fw->addInternalService(
                'name' => 'ldap',
                'description' => 'LDAP',
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => 389,
                'target'  => 'deny',
                );
        $fw->saveConfigRecursive();
    }

    # Execute initial-setup script
    $self->SUPER::initialSetup($version);
}

# Method: enableActions
#
#   Override EBox::Module::Service::enableActions
#
sub enableActions
{
    my ($self) = @_;

    # Stop slapd daemon
    EBox::Sudo::root(
        'invoke-rc.d slapd stop || true',
        'stop ebox.slapd        || true',
        'cp /usr/share/zentyal-users/slapd.default.no /etc/default/slapd'
    );

    my $dn = $self->model('Mode')->dnValue();
    my $password = $self->_genPassword(EBox::Config::conf() . 'ldap.passwd');
    my $password_ro = $self->_genPassword(EBox::Config::conf() . 'ldap_ro.passwd');
    my $opts = [
        'dn' => $dn,
        'password' => $password,
        'password_ro' => $password_ro,
    ];

    # Prepare ldif files
    my $LDIF_CONFIG = EBox::Config::tmp() . "slapd-config.ldif";
    my $LDIF_DB = EBox::Config::tmp() . "slapd-database.ldif";

    EBox::Module::Base::writeConfFileNoCheck($LDIF_CONFIG, "users/config.ldif.mas", $opts);
    EBox::Module::Base::writeConfFileNoCheck($LDIF_DB, "users/database.ldif.mas", $opts);

    # Preload base LDAP data
    $self->_loadLDAP($dn, $LDIF_CONFIG, $LDIF_DB);

    $self->_manageService('start');
    $self->ldap->clearConn();

    # Setup NSS (needed if some user is added before save changes)
    $self->_setConf();

    # Create default group
    EBox::UsersAndGroups::Group->create(DEFAULTGROUP, 'All users', 1);

    # Perform LDAP actions (schemas, indexes, etc)
    EBox::info('Performing first LDAP actions');
    try {
        $self->performLDAPActions();
    } otherwise {
        throw EBox::Exceptions::External(__('Error performing users initialization'));
    };

    # Execute enable-module script
    $self->SUPER::enableActions();

    # Configure SOAP to listen for new slaves
    $self->master->confSOAPService();
    $self->master->setupMaster();

    # mark apache as changed to avoid problems with getpwent calls, it needs
    # to be restarted to be aware of the new nsswitch conf
    EBox::Global->modInstance('apache')->setAsChanged();
}


# Load LDAP from config + data files
sub _loadLDAP
{
    my ($self, $dn, $LDIF_CONFIG, $LDIF_DB) = @_;
    EBox::info('Creating LDAP database...');
    try {
        EBox::Sudo::root(
            # Remove current database (if any)
            'rm -rf ' . LDAP_CONFDIR . ' ' . LDAP_DATADIR,
            'rm -rf ' . LDAP_CONFDIR . ' ' . LDAP_DATADIR,
            'mkdir -p ' . LDAP_CONFDIR . ' ' . LDAP_DATADIR,
            'chmod 750 ' . LDAP_CONFDIR . ' ' . LDAP_DATADIR,

            # Create database (config + structure)
            'slapadd -F ' . LDAP_CONFDIR . " -b cn=config -l $LDIF_CONFIG",
            'slapadd -F ' . LDAP_CONFDIR . " -b $dn -l $LDIF_DB",

            # Fix permissions and clean temp files
            'chown -R openldap.openldap ' . LDAP_CONFDIR . ' ' . LDAP_DATADIR,
            "rm -f $LDIF_CONFIG $LDIF_DB",
        );
    }
    catch EBox::Exceptions::Sudo::Command with {
        my $exception = shift;
        EBox::error('Trying to setup ldap failed, exit value: ' .
                $exception->exitValue());
        throw EBox::Exceptions::External(__('Error while creating users and groups database.'));
    };
    EBox::debug('done');
}


# Generate, store in the given file and return a password
sub _genPassword
{
    my ($self, $file) = @_;

    my $pass = EBox::Util::Random::generate(20);
    my ($login,$password,$uid,$gid) = getpwnam('ebox');
    EBox::Module::Base::writeFile($file, $pass,
            { mode => '0600', uid => $uid, gid => $gid });

    return $pass;
}


# Method: wizardPages
#
#   Override EBox::Module::Base::wizardPages
#
sub wizardPages
{
    my ($self) = @_;
    return [{ page => '/UsersAndGroups/Wizard/Users', order => 300 }];
}


# Method: _setConf
#
#       Override EBox::Module::Service::_setConf
#
sub _setConf
{
    my ($self) = @_;

    my $ldap = $self->ldap;
    EBox::Module::Base::writeFile(SECRETFILE, $ldap->getPassword(),
        { mode => '0600', uid => 0, gid => 0 });

    my  $dn = $ldap->dn;
    my $nsspw = read_file(EBox::Config::conf() . 'ldap_ro.passwd');
    my @array = ();
    push(@array, 'ldap' => EBox::Ldap::LDAPI);
    push(@array, 'basedc'    => $dn);
    push(@array, 'binddn'    => 'cn=zentyalro,' . $dn);
    push(@array, 'bindpw'    => $nsspw);
    push(@array, 'rootbinddn'=> 'cn=zentyal,' . $dn);
    push(@array, 'usersdn'   => USERSDN . ',' . $dn);
    push(@array, 'groupsdn'  => GROUPSDN . ',' . $dn);
    push(@array, 'computersdn' => 'ou=Computers,' . $dn);

    $self->writeConfFile(LIBNSSLDAPFILE, "users/ldap.conf.mas",
            \@array);

    $self->_setupNSSPAM();

    # Configure soap service
    $self->master->confSOAPService();

    # Configure as slave if enabled
    $self->master->setupSlave();
}

sub _setupNSSPAM
{
    my ($self) = @_;

    my @array;
    my $umask = EBox::Config::configkey('dir_umask');
    push (@array, 'umask' => $umask);

    $self->writeConfFile(AUTHCONFIGTMPL, 'users/acc-ebox.mas',
               \@array);

    my $enablePam = $self->model('PAM')->enable_pamValue();
    my @cmds;
    push (@cmds, 'auth-client-config -a -p ebox');

    unless ($enablePam) {
        push (@cmds, 'auth-client-config -a -p ebox -r');
    }

    push (@cmds, 'auth-client-config -t nss -p ebox');
    EBox::Sudo::root(@cmds);
}


# Method: editableMode
#
#       Check if users and groups can be edited.
#
#       Returns true if mode is master
#
sub editableMode
{
    my ($self) = @_;

    return 1; # TODO check sync providers
}

# Method: _daemons
#
#       Override EBox::Module::Service::_daemons
#
sub _daemons
{
    my ($self) = @_;

    return [
        { 'name' => 'ebox.slapd' },
    ];
}

# Method: _enforceServiceState
#
#       Override EBox::Module::Service::_enforceServiceState
#
sub _enforceServiceState
{
    my ($self) = @_;
    $self->SUPER::_enforceServiceState();

    # Clear LDAP connection
    $self->ldap->clearConn();
}

# Method: modelClasses
#
#       Override <EBox::Model::ModelProvider::modelClasses>
#
sub modelClasses
{
    return [
        'EBox::UsersAndGroups::Model::Mode',
        'EBox::UsersAndGroups::Model::Users',
        'EBox::UsersAndGroups::Model::Groups',
        'EBox::UsersAndGroups::Model::Password',
        'EBox::UsersAndGroups::Model::LdapInfo',
        'EBox::UsersAndGroups::Model::PAM',
        'EBox::UsersAndGroups::Model::AccountSettings',
        'EBox::UsersAndGroups::Model::OUs',
        'EBox::UsersAndGroups::Model::Slaves',
        'EBox::UsersAndGroups::Model::Master',
        'EBox::UsersAndGroups::Model::SlavePassword',
    ];
}

# Method: compositeClasses
#
#       Override <EBox::Model::CompositeProvider::compositeClasses>
#
sub compositeClasses
{
    return [
        'EBox::UsersAndGroups::Composite::Settings',
        'EBox::UsersAndGroups::Composite::UserTemplate',
        'EBox::UsersAndGroups::Composite::Sync',
    ];
}


# Method: groupsDn
#
#       Returns the dn where the groups are stored in the ldap directory
#       Accepts an optional parameter as base dn instead of getting it
#       from the local LDAP repository
#
# Returns:
#
#       string - dn
#
sub groupsDn
{
    my ($self, $dn) = @_;
    unless(defined($dn)) {
        $dn = $self->ldap->dn();
    }
    return GROUPSDN . "," . $dn;
}


# Method: groupDn
#
#    Returns the dn for a given group. The group don't have to existst
#
#   Parameters:
#       group
#
#  Returns:
#     dn for the group
sub groupDn
{
    my ($self, $group) = @_;
    $group or throw EBox::Exceptions::MissingArgument('group');

    my $dn = "cn=$group," .  $self->groupsDn;
    return $dn;
}

# Method: usersDn
#
#       Returns the dn where the users are stored in the ldap directory.
#       Accepts an optional parameter as base dn instead of getting it
#       from the local LDAP repository
#
# Returns:
#
#       string - dn
#
sub usersDn
{
    my ($self, $dn) = @_;
    unless(defined($dn)) {
        $dn = $self->ldap->dn();
    }
    return USERSDN . "," . $dn;
}

# Method: userDn
#
#    Returns the dn for a given user. The user don't have to existst
#
#   Parameters:
#       user
#
#  Returns:
#     dn for the user
sub userDn
{
    my ($self, $user) = @_;
    $user or throw EBox::Exceptions::MissingArgument('user');

    my $dn = "uid=$user," .  $self->usersDn;
    return $dn;
}



# Init a new user (home and permissions)
sub initUser
{
    my ($self, $user, $password) = @_;

    my $mk_home = EBox::Config::configkey('mk_home');
    $mk_home = 'yes' unless $mk_home;
    if ($mk_home eq 'yes') {
        my $home = $user->home();
        if ($home and ($home ne '/dev/null') and (not -e $home)) {
            my @cmds;

            my $quser = shell_quote($user->name());
            my $qhome = shell_quote($home);
            my $group = DEFAULTGROUP;
            push(@cmds, "mkdir -p `dirname $qhome`");
            push(@cmds, "cp -dR --preserve=mode /etc/skel $qhome");
            push(@cmds, "chown -R $quser:$group $qhome");

            my $dir_umask = oct(EBox::Config::configkey('dir_umask'));
            my $perms = sprintf("%#o", 00777 &~ $dir_umask);
            push(@cmds, "chmod $perms $qhome");

            EBox::Sudo::root(@cmds);
        }
    }
}


# Reload nscd daemon if it's installed
sub reloadNSCD
{
    if ( -f '/etc/init.d/nscd' ) {
        try {
           EBox::Sudo::root('/etc/init.d/nscd reload');
       } otherwise {};
   }
}


# Method: users
#
#       Returns an array containing all the users (not system users)
#
# Parameters:
#       system - show system users also (default: false)
#
# Returns:
#
#       array ref - holding the users. Each user is represented by a hash reference
#       with the same format than the return value of userInfo
#
sub users
{
    my ($self, $system) = @_;

    return [] if (not $self->isEnabled());

    my %args = (
        base => $self->ldap->dn(),
        filter => 'objectclass=posixAccount',
        scope => 'sub',
    );

    my $result = $self->ldap->search(\%args);

    my @users = ();
    foreach my $entry ($result->sorted('uid'))
    {
        my $user = new EBox::UsersAndGroups::User(entry => $entry);

        # Include system users?
        next if (not $system and $user->system());

        push (@users, $user);
    }

    return \@users;
}

# Method: groups
#
#       Returns an array containing all the groups
#
#   Parameters:
#       system - show system groups (default: false)
#
# Returns:
#
#       array - holding the groups
#
# Warning:
#
#   the group hashes are NOT the sames that we get from groupInfo, the keys are:
#     account(group name), desc (description) and gid
sub groups
{
    my ($self, $system) = @_;

    return [] if (not $self->isEnabled());

    my %args = (
        base => $self->ldap->dn(),
        filter => 'objectclass=zentyalGroup',
        scope => 'sub',
    );

    my $result = $self->ldap->search(\%args);

    my @groups = ();
    foreach my $entry ($result->sorted('cn'))
    {
        my $group = new EBox::UsersAndGroups::Group(entry => $entry);

        # Include system users?
        next if (not $system and $group->system());

        push (@groups, $group);
    }

    return \@groups;
}

# Method: ous
#
#       Returns an array containing all the OUs
#
# Returns:
#
#       array ref - holding the OUs
#
sub ous
{
    my ($self) = @_;

    return [] if (not $self->isEnabled());

    my %args = (
        base => $self->ldap->dn(),
        filter => 'objectclass=organizationalUnit',
        scope => 'sub',
    );

    my $result = $self->ldap->search(\%args);

    my @ous = ();
    foreach my $entry ($result->entries())
    {
        my $ou = new EBox::UsersAndGroups::OU(entry => $entry);
        push (@ous, $ou);
    }

    return \@ous;
}


# Method: _modsLdapUserbase
#
# Returns modules implementing LDAP user base interface
#
# Parameters:
#   ignored_modules (Optional) - array ref to a list of module names to ignore
#
sub _modsLdapUserBase
{
    my ($self, $ignored_modules) = @_;

    my $global = EBox::Global->modInstance('global');
    my @names = @{$global->modNames};

    $ignored_modules or $ignored_modules = [];

    my @modules;
    foreach my $name (@names) {
        next if ($name eq any @{$ignored_modules});

        my $mod = EBox::Global->modInstance($name);

        if ($mod->isa('EBox::LdapModule')) {
            if ($mod->isa('EBox::Module::Service')) {
                if ($name ne $self->name()) {
                    $mod->configured() or
                        next;
                }
            }
            push (@modules, $mod->_ldapModImplementation);
        }
    }

    return \@modules;
}


# Method: _allSlaves
#
# Returns all slaves from LDAP Sync Provider
#
sub _allSlaves
{
    my ($self) = @_;

    my $global = EBox::Global->modInstance('global');
    my @names = @{$global->modNames};

    my @modules;
    foreach my $name (@names) {
        my $mod = EBox::Global->modInstance($name);

        if ($mod->isa('EBox::UsersAndGroups::SyncProvider')) {
            push (@modules, @{$mod->slaves()});
        }
    }

    return \@modules;
}


# Method: notifyModsLdapUserBase
#
#   Notify all modules implementing LDAP user base interface about
#   a change in users or groups
#
# Parameters:
#
#   signal - Signal name to notify the modules (addUser, delUser, modifyGroup, ...)
#   args - single value or array ref containing signal parameters
#   ignored_modules - array ref of modnames to ignore (won't be notified)
#
sub notifyModsLdapUserBase
{
    my ($self, $signal, $args, $ignored_modules) = @_;

    # convert signal to method name
    my $method = '_' . $signal;

    # convert args to array if it is a single value
    unless (ref($args) eq 'ARRAY') {
        $args = [ $args ];
    }

    my $basedn = $args->[0]->baseDn();
    my $defaultOU = ($basedn eq $self->usersDn() or $basedn eq $self->groupsDn());
    foreach my $mod (@{$self->_modsLdapUserBase($ignored_modules)}) {

        # Skip modules not supporting multiple OU if not default OU
        next unless ($mod->multipleOUSupport or $defaultOU);

        # TODO catch errors here?
        $mod->$method(@{$args});
    }

    # Notify slaves
    foreach my $slave (@{$self->_allSlaves}) {
        $slave->sync($signal, $args);
    }
}



# Method: defaultUserModels
#
#   Returns all the defaultUserModels from modules implementing
#   <EBox::LdapUserBase>
sub defaultUserModels
{
    my ($self) = @_;
    my @models;
    for my $module  (@{$self->_modsLdapUserBase()}) {
        my $model = $module->defaultUserModel();
        push (@models, $model) if (defined($model));
    }
    return \@models;
}

# Method: allUserAddOns
#
#       Returns all the mason components from those modules implementing
#       the function _userAddOns from EBox::LdapUserBase
#
# Parameters:
#
#       user - username
#
# Returns:
#
#       array ref - holding all the components and parameters
#
sub allUserAddOns
{
    my ($self, $user) = @_;

    my $global = EBox::Global->modInstance('global');
    my @names = @{$global->modNames};

    my $defaultOU = ($user->baseDn() eq $self->usersDn());

    my @modsFunc = @{$self->_modsLdapUserBase()};
    my @components;
    foreach my $mod (@modsFunc) {
        # Skip modules not support multiple OU, if not default OU
        next unless ($mod->multipleOUSupport or $defaultOU);

        my $comp = $mod->_userAddOns($user);
        if ($comp) {
            push (@components, $comp);
        }
    }

    return \@components;
}

# Method: allGroupAddOns
#
#       Returns all the mason components from those modules implementing
#       the function _groupAddOns from EBox::LdapUserBase
#
# Parameters:
#
#       group  - group name
#
# Returns:
#
#       array ref - holding all the components and parameters
#
sub allGroupAddOns
{
    my ($self, $group) = @_;

    my $global = EBox::Global->modInstance('global');
    my @names = @{$global->modNames};

    my @modsFunc = @{$self->_modsLdapUserBase()};
    my @components;
    foreach my $mod (@modsFunc) {
        my $comp = $mod->_groupAddOns($group);
        push (@components, $comp) if ($comp);
    }

    return \@components;
}

# Method: allWarning
#
#       Returns all the the warnings provided by the modules when a certain
#       user or group is going to be deleted. Function _delUserWarning or
#       _delGroupWarning is called in all module implementing them.
#
# Parameters:
#
#       object - Sort of object: 'user' or 'group'
#       name - name of the user or group
#
# Returns:
#
#       array ref - holding all the warnings
#
sub allWarnings
{
    my ($self, $object, $name) = @_;

    my @modsFunc = @{$self->_modsLdapUserBase()};
    my @allWarns;
    foreach my $mod (@modsFunc) {
        my $warn = undef;
        if ($object eq 'user') {
            $warn = $mod->_delUserWarning($name);
        } else {
            $warn = $mod->_delGroupWarning($name);
        }
        push (@allWarns, $warn) if ($warn);
    }

    return \@allWarns;
}

# Method: _supportActions
#
#       Overrides EBox::ServiceModule::ServiceInterface method.
#
sub _supportActions
{
    return undef;
}

# Method: menu
#
#       Overrides EBox::Module method.
#
sub menu
{
    my ($self, $root) = @_;

    my $separator = 'Office';
    my $order = 510;

    my $folder = new EBox::Menu::Folder('name' => 'UsersAndGroups',
                                        'text' => $self->printableName(),
                                        'separator' => $separator,
                                        'order' => $order);

    if ($self->configured()) {
        if ($self->editableMode()) {
            $folder->add(new EBox::Menu::Item('url' => 'UsersAndGroups/Users',
                                              'text' => __('Users'), order => 10));
            $folder->add(new EBox::Menu::Item('url' => 'UsersAndGroups/Groups',
                                              'text' => __('Groups'), order => 20));
            $folder->add(new EBox::Menu::Item('url' => 'Users/Composite/UserTemplate',
                                              'text' => __('User Template'), order => 30));

        } else {
            $folder->add(new EBox::Menu::Item(
                        'url' => 'Users/View/Users',
                        'text' => __('Users'), order => 10));
            $folder->add(new EBox::Menu::Item(
                        'url' => 'Users/View/Groups',
                        'text' => __('Groups'), order => 20));
            $folder->add(new EBox::Menu::Item('url' => 'Users/Composite/UserTemplate',
                                              'text' => __('User Template'), order => 30));
        }

        if (EBox::Config::configkey('multiple_ous')) {
            $folder->add(new EBox::Menu::Item(
                        'url' => 'Users/View/OUs',
                        'text' => __('Organizational Units'), order => 25));
        }

        $folder->add(new EBox::Menu::Item(
                    'url' => 'Users/Composite/Sync',
                    'text' => __('Synchronization'), order => 40));

        $folder->add(new EBox::Menu::Item(
                    'url' => 'Users/Composite/Settings',
                    'text' => __('LDAP Settings'), order => 50));

    } else {
        $folder->add(new EBox::Menu::Item('url' => 'Users/View/Mode',
                                          'text' => __('Configure DN'),
                                          'separator' => $separator,
                                          'order' => 0));
    }

    $root->add($folder);
}

# EBox::UserCorner::Provider implementation

# Method: userMenu
#
sub userMenu
{
    my ($self, $root) = @_;

    $root->add(new EBox::Menu::Item('url' => 'Users/View/Password',
                                    'text' => __('Password')));
}


# Method: syncJournalDir
#
#   Returns the path holding sync pending actions for
#   the given slave.
#   If the directory does not exists, it will be created;
#
sub syncJournalDir
{
    my ($self, $slave) = @_;

    my $dir = JOURNAL_DIR . $slave->name();
    my $journalsDir = JOURNAL_DIR;

    # Create if the dir does not exists
    unless (-d $dir) {
        EBox::Sudo::root(
            "mkdir -p $dir",
            "chown -R ebox:ebox $journalsDir",
            "chmod 0700 $journalsDir",
        );
    }

    return $dir;
}


# LdapModule implementation
sub _ldapModImplementation
{
    return new EBox::LdapUserImplementation();
}

# SyncProvider implementation
sub slaves
{
    my ($self) = @_;

    my $model = $self->model('Slaves');

    my @slaves;
    foreach my $id (@{$model->ids()}) {
        my $row = $model->row($id);
        my $host = $row->valueByName('host');
        my $port = $row->valueByName('port');

        push (@slaves, new EBox::UsersSync::Slave($host, $port));
    }

    return \@slaves;
}


# Master-Slave UsersSync object
sub master
{
    my ($self) = @_;

    unless ($self->{ms}) {
        $self->{ms} = new EBox::UsersSync::Master();
    }
    return $self->{ms};
}

sub dumpConfig
{
    my ($self, $dir, %options) = @_;

    $self->ldap->dumpLdapConfig($dir);
    $self->ldap->dumpLdapData($dir);
    if ($options{bug}) {
        my $file = $self->ldap->ldifFile($dir, 'data');
        $self->_removePasswds($file);
    }
    else {
        # Save rootdn passwords
        copy(EBox::Config::conf() . 'ldap.passwd', $dir);
        copy(EBox::Config::conf() . 'ldap_ro.passwd', $dir);
    }
}

sub _usersInEtcPasswd
{
    my ($self) = @_;
    my @users;

    my @lines = File::Slurp::read_file('/etc/passwd');
    foreach my $line (@lines) {
        my ($user) = split ':', $line, 2;
        push @users, $user;
    }

    return \@users;
}

sub restoreBackupPreCheck
{
    my ($self, $dir) = @_;

    my %etcPasswdUsers = map { $_ => 1 } @{ $self->_usersInEtcPasswd() };

    my @usersToRestore = @{ $self->ldap->usersInBackup($dir) };
    foreach my $user (@usersToRestore) {
        if (exists $etcPasswdUsers{$user}) {
            throw EBox::Exceptions::External(__x('Cannot restore because LDAP user {user} already exists as /etc/passwd user. Delete or rename this user and try again', user => $user));
        }
    }
}

sub restoreConfig
{
    my ($self, $dir) = @_;
    my $mode = $self->mode();

    $self->_manageService('stop');

    my $LDIF_CONFIG = $self->ldap->ldifFile($dir, 'config');
    my $LDIF_DB = $self->ldap->ldifFile($dir, 'data');

    # retrieve base dn from backup
    my $fd;
    open($fd, $LDIF_DB);
    my $line = <$fd>;
    chomp($line);
    my @parts = split(/ /, $line);
    my $base = $parts[1];

    $self->_loadLDAP($base, $LDIF_CONFIG, $LDIF_DB);

    # Restore passwords
    copy($dir . '/ldap.passwd', EBox::Config::conf());
    copy($dir . '/ldap_ro.passwd', EBox::Config::conf());
    EBox::debug("Copying $dir/ldap.passwd to " . EBox::Config::conf());
    chmod(0600, "$dir/ldap.passwd", "$dir/ldap_ro.passwd");

    $self->_manageService('start');
    $self->ldap->clearConn();

    # Save conf to enable NSS (and/or) PAM
    $self->_setConf();

    for my $user (@{$self->users()}) {

        # Init local users
        if ($user->baseDn eq $self->usersDn) {
            $self->initUser($user);
        }

        # Notify modules
        $self->notifyModsLdapUserBase('addUser', $user);
    }
}

sub _removePasswds
{
  my ($self, $file) = @_;

  my $anyPasswdAttr = any(qw(
              userPassword
              sambaLMPassword
              sambaNTPassword
              )
          );
  my $passwordSubstitution = "password";

  my $FH_IN;
  open $FH_IN, "<$file" or
      throw EBox::Exceptions::Internal ("Cannot open $file: $!");

  my ($FH_OUT, $tmpFile) = tempfile(DIR => EBox::Config::tmp());

  foreach my $line (<$FH_IN>) {
      my ($attr, $value) = split ':', $line;
      if ($attr eq $anyPasswdAttr) {
          $line = $attr . ': ' . $passwordSubstitution . "\n";
      }

      print $FH_OUT $line;
  }

  close $FH_IN  or
      throw EBox::Exceptions::Internal ("Cannot close $file: $!");
  close $FH_OUT or
      throw EBox::Exceptions::Internal ("Cannot close $tmpFile: $!");

  File::Copy::move($tmpFile, $file);
  unlink $tmpFile;
}


# Method: authUser
#
#   try to authenticate the given user with the given password
#
sub authUser
{
    my ($self, $user, $password) = @_;

    my $authorized = 0;
    my $ldap = EBox::Ldap::safeConnect(EBox::Ldap::LDAPI);
    try {
        EBox::Ldap::safeBind($ldap, $self->userDn($user), $password);
        $authorized = 1; # auth ok
    } otherwise {
        $authorized = 0; # auth failed
    };
    return $authorized;
}


sub listSchemas
{
    my ($self, $ldap) = @_;

    my %args = (
        'base' => 'cn=schema,cn=config',
        'scope' => 'one',
        'filter' => "(objectClass=olcSchemaConfig)"
    );
    my $result = $ldap->search(%args);

    my @schemas = map { $_->get_value('cn') } $result->entries();
    return \@schemas;
}


sub mode
{
    my ($self) = @_;

    return 'master';
}

1;
