# Copyright (C) 2013-2014 Zentyal S.L.
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

use strict;
use warnings;

package EBox::OpenChange;
use base qw(
    EBox::Module::Kerberos
    EBox::VDomainModule
    EBox::CA::Observer
);

use EBox::Config;
use EBox::DBEngineFactory;
use EBox::Exceptions::Sudo::Command;
use EBox::Exceptions::External;
use EBox::Gettext;
use EBox::Global;
use EBox::Menu::Item;
use EBox::Module::Base;
use EBox::OpenChange::LdapUser;
use EBox::OpenChange::ExchConfigurationContainer;
use EBox::OpenChange::ExchOrganizationContainer;
use EBox::OpenChange::VDomainsLdap;
use EBox::Samba;
use EBox::Sudo;
use EBox::Util::Certificate;

use TryCatch::Lite;
use String::Random;
use File::Basename;

use constant SOGO_PORT => 20000;
use constant SOGO_DEFAULT_PREFORK => 1;
use constant SOGO_APACHE_CONF => '/etc/apache2/conf-available/sogo.conf';

use constant SOGO_DEFAULT_FILE => '/etc/default/sogo';
use constant SOGO_CONF_FILE => '/etc/sogo/sogo.conf';
use constant SOGO_PID_FILE => '/var/run/sogo/sogo.pid';
use constant SOGO_LOG_FILE => '/var/log/sogo/sogo.log';

use constant OCSMANAGER_CONF_FILE => '/etc/ocsmanager/ocsmanager.ini';
use constant OCSMANAGER_APACHE_CONF  => '/etc/apache2/conf-available/zentyal-ocsmanager.conf';
use constant OCSMANAGER_DOMAIN_PEM => '/etc/ocsmanager/domain.pem';

use constant RPCPROXY_AUTH_CACHE_DIR => '/var/cache/ntlmauthhandler';
use constant RPCPROXY_STOCK_CONF_FILE => '/etc/apache2/conf.d/rpcproxy.conf';
use constant REWRITE_POLICY_FILE => '/etc/postfix/generic';

use constant OPENCHANGE_CONF_FILE => '/etc/samba/openchange.conf';
use constant OPENCHANGE_MYSQL_PASSWD_FILE => EBox::Config->conf . '/openchange/mysql.passwd';
use constant OPENCHANGE_IMAP_PASSWD_FILE => EBox::Samba::PRIVATE_DIR() . 'mapistore/master.password';

use constant OC_NOTIF_SERVICE_CONF_PATH => '/etc/openchange/';
use constant OC_NOTIF_SERVICE_CONF_FILE => OC_NOTIF_SERVICE_CONF_PATH . 'notification-service.cfg';
use constant APACHE_PORTS_FILE => '/etc/apache2/ports.conf';

# Method: _create
#
#   The constructor, instantiate module
#
sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(name => 'openchange',
                                      printableName => 'OpenChange',
                                      @_);
    bless ($self, $class);
    return $self;
}

# Method: initialSetup
#
# Overrides:
#
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    unless ($version) {
        my $firewall = $self->global()->modInstance('firewall');
        $firewall->setInternalService('HTTPS', 'accept');
        $firewall->saveConfigRecursive();
    }

    if (defined($version) and  (EBox::Util::Version::compare($version, '3.5') < 0)) {
        $self->_migrateFormKeys();
    }

    if (defined($version) and (EBox::Util::Version::compare($version, '3.3.3') < 0)) {
        $self->_migrateOutgoingDomain();
    }

    if (defined($version) and  (EBox::Util::Version::compare($version, '3.5.3') < 0)) {
        EBox::debug("Migrating from $version");
        $self->_migrateCerts();
    }

    # Migration from 3.5 to 4.0
    if (defined($version) and  (EBox::Util::Version::compare($version, '4.0') < 0)) {
        EBox::Sudo::silentRoot('a2disconf sogo');
        EBox::Sudo::silentRoot('a2enmod ssl');
        EBox::Sudo::silentRoot('service apache2 reload');
        EBox::Sudo::root('rm -f /etc/apache2/conf-available/sogo.conf');
    }

    if ($self->changed()) {
        $self->saveConfigRecursive();
    }
}

# Migration of form keys after extracting the rewrite rule for outgoing domain
# from the provision form.
#
sub _migrateOutgoingDomain
{
  my ($self) = @_;

  my $oldKeyValue = $self->get('Provision/keys/form');
  $self->set('Configuration/keys/form', $oldKeyValue);
}

# Migration of form keys to better names (between development versions)
#
# * Migrate redis keys from firstorganization to organizationname and firstorganizationunit to administrativegroup
#
sub _migrateFormKeys
{
    my ($self) = @_;
    my $modelName = 'Provision';
    my @keys = ("openchange/conf/$modelName/keys/form", "openchange/ro/$modelName/keys/form");

    my $state = $self->get_state();
    my $keyField = 'organizationname';
    my $redis = $self->redis();
    foreach my $key (@keys) {
        my $value = $redis->get($key);
        if (defined $value->{firstorganization}) {
            $state->{$modelName}->{$keyField} = $value->{firstorganization};
            delete $value->{firstorganization};
        }
        if (defined $value->{organizationname}) {
            $state->{$modelName}->{$keyField} = $value->{organizationname};
            delete $value->{organizationname};
        }
        if (defined $value->{firstorganizationunit}) {
            delete $value->{firstorganizationunit};
        }
        if (defined $value->{administrativegroup}) {
            delete $value->{administrativegroup};
        }
        $redis->set($key, $value);
    }
    if ($self->isProvisioned()) {
        # The organization name is only useful if the server is already provisioned.
        $self->set_state($state);
    }
}

# Migrate RPC/Proxy certificates to use the proper ones using the CA
# to make RPC/Proxy and Autodiscover work together
sub _migrateCerts
{
    my ($self) = @_;

    if ($self->isProvisioned()) {
        try {
            my $domain = $self->model('Configuration')->row()->printableValueByName('outgoingDomain');
            my $ca = $self->global()->modInstance('ca');
            if ($ca->getCertificateMetadata(cn => $domain)) {
                $ca->revokeCertificate(commonName => $domain,
                                       reason     => 'superseded',
                                       force      => 1);
            }
            $self->_setCert($domain);
        } catch ($ex) {
            EBox::error("Impossible to migrate certificates: $ex");
        }
        # Remove now useless certificate
        my $oldRPCProxyCert = EBox::Config::conf() . 'openchange/ssl/ssl.pem';
        foreach my $oldCert (('/etc/ocsmanager/autodiscover.pem', $oldRPCProxyCert)) {
            EBox::Sudo::silentRoot("rm -rf '$oldCert'");
        }
    }
}

# Method: actions
#
#        Explain the actions the module must make to configure the
#        system. Check overriden method for details
#
# Overrides:
#
#        <EBox::Module::Service::actions>
sub actions
{
    return [
            {
             'action' => __('Enable proxy, proxy_http and headers Apache 2 modules.'),
             'reason' => __('To make OpenChange Webmail be accesible at http://ip/SOGo/.'),
             'module' => 'sogo'
            },
    ];
}


# Method: enableActions
#
# Action to do when openchange module is enabled for first time
#
sub enableActions
{
    my ($self) = @_;

    # Execute enable-module script
    $self->SUPER::enableActions();
    $self->_setupDNS();

    # FIXME: move this to the new "Enable Webmail" checkbox
    #my $mail = EBox::Global->modInstance('mail');
    #unless ($mail->imap() or $mail->imaps()) {
    #    throw EBox::Exceptions::External(__x('OpenChange Webmail module needs IMAP or IMAPS service enabled if ' .
    #                                         'using Zentyal mail service. You can enable it at ' .
    #                                         '{openurl}Mail -> General{closeurl}.',
    #                                         openurl => q{<a href='/Mail/Composite/General'>},
    #                                         closeurl => q{</a>}));
    #}
}

sub _daemonsToDisable
{
    my ($self) = @_;

    my $daemons = [
        {
            name => 'openchange-ocsmanager',
            type => 'init.d',
        },
        {
            name => 'ocnotification',
            type => 'upstart',
        },
        {
            name => 'sogo',
            type => 'init.d',
            # FIXME: precondition only if enabled!
        }
    ];
    return $daemons;
}

# Method: _daemons
#
# Overrides:
#
#      <EBox::Module::Service::_daemons>
#
sub _daemons
{
    my ($self) = @_;
    my $daemons = [
        {
            name         => 'zentyal.ocsmanager',
            type         => 'upstart',
            precondition => sub { return $self->isProvisioned() },
        },
        {
            name         => 'ocnotification',
            type         => 'upstart',
            precondition => sub { return $self->isProvisioned() },
        }
    ];

    return $daemons;
}

# Method: isRunning
#
#   Links Openchange running status to Samba status.
#
# Overrides: <EBox::Module::Service::isRunning>
#
sub isRunning
{
    my ($self) = @_;

    my $running = $self->SUPER::isRunning();

    if ($running) {
        my $usersMod = $self->global()->modInstance('samba');
        return $usersMod->isRunning();
    } else {
        return $running;
    }
}

sub _rpcProxyEnabled
{
    my ($self) = @_;
    if (not $self->isProvisioned() or not $self->isEnabled()) {
        return 0;
    }

    my $rpcpSettings = $self->model('RPCProxy');
    return $rpcpSettings->enabled();
}

sub usedFiles
{
    my @files = ();
    push (@files, {
        file => SOGO_DEFAULT_FILE,
        reason => __('To configure sogo daemon'),
        module => 'openchange'
    });
    push (@files, {
        file => SOGO_CONF_FILE,
        reason => __('To configure sogo parameters'),
        module => 'openchange'
    });
    push (@files, {
        file => OCSMANAGER_CONF_FILE,
        reason => __('To configure autodiscovery service'),
        module => 'openchange'
    });
    push (@files, {
        file => RPCPROXY_STOCK_CONF_FILE,
        reason => __('Remove RPC Proxy stock file to avoid interference'),
        module => 'openchange'
    });
    push (@files, {
        file => SOGO_APACHE_CONF,
        reason => __('To make SOGo webmail available'),
        module => 'sogo'
    });
    push (@files, {
        file => OCSMANAGER_APACHE_CONF,
        reason => __('To make autodiscovery service available'),
        module => 'sogo'
    });

    return \@files;
}

sub writeSambaConfig
{
    my ($self) = @_;

    my $openchangeProvisionedWithMySQL = $self->isProvisionedWithMySQL();
    my $openchangeConnectionString = undef;
    my $oc = [];
    if ($openchangeProvisionedWithMySQL) {
        $openchangeConnectionString = $self->connectionString();
        # format of connection string: "mysql://user:password@localhost/db_name
        my ($mysqlUser, $mysqlPass, $mysqlHost, $mysqlDb) =
            $openchangeConnectionString =~ /mysql:\/\/(\w+):(\w+)\@(\w+)\/(\w+)/;
        push (@{$oc}, 'openchangeNamedpropsMysqlUser' => $mysqlUser);
        push (@{$oc}, 'openchangeNamedpropsMysqlPass' => $mysqlPass);
        push (@{$oc}, 'openchangeNamedpropsMysqlHost' => $mysqlHost);
        push (@{$oc}, 'openchangeNamedpropsMysqlDb' => $mysqlDb);
    }
    push (@{$oc}, 'openchangeProvisionedWithMySQL' => $openchangeProvisionedWithMySQL);
    push (@{$oc}, 'openchangeConnectionString' => $openchangeConnectionString);
    push (@{$oc}, 'brokerHost'      => EBox::Config::configkey('oc_notif_broker_host'));
    push (@{$oc}, 'brokerPort'      => EBox::Config::configkey('oc_notif_broker_port'));
    push (@{$oc}, 'brokerUser'      => EBox::Config::configkey('oc_notif_broker_user'));
    push (@{$oc}, 'brokerPass'      => EBox::Config::configkey('oc_notif_broker_pass'));
    push (@{$oc}, 'brokerVHost'     => EBox::Config::configkey('oc_notif_broker_vhost'));
    $self->writeConfFile(OPENCHANGE_CONF_FILE, 'samba/openchange.conf.mas', $oc,
                         { 'uid' => 'root', 'gid' => 'ebox', mode => '640' });
}

# Method: _setConf
#
# Overrides:
#
#       <EBox::Module::Base::_setConf>
#
sub _setConf
{
    my ($self) = @_;

    my $state = $self->get_state();
    if ($state->{provision_from_wizard}) {
        my $orgName = $state->{provision_from_wizard}->{orgName};
        my $provisionModel = $self->model('Provision');
        $provisionModel->provision($orgName);
        delete $state->{provision_from_wizard};
        $self->set_state($state);
    }

    $self->_writeSOGoDefaultFile();
    $self->_writeSOGoConfFile();
    $self->_setupSOGoDatabase();
    $self->_writeNotificationServiceConf();

    $self->_setApachePortsConf();

    $self->_setOCSManagerConf();

    $self->_setRPCProxyConf();

    $self->_writeRewritePolicy();

    # FIXME: this may cause unexpected samba restarts during save changes, etc
    #$self->_writeCronFile();

    $self->_setupActiveSync();

    $self->_setSOGoApacheConf();

    $self->_setDomainCertificate();
}

sub _postServiceHook
{
    my ($self, $enabled) = @_;

    # FIXME: only if webmail enabled
    if ($enabled) {
        EBox::Sudo::root('service sogo restart');
        # FIXME: common way to restart apache for rpcproxy, sogo and activesync only if there are changes?
        #        currently we are doing more than necessary
        EBox::Sudo::root('service apache2 restart');
    }
}

sub _setDomainCertificate
{
    my ($self) = @_;

    if ($self->isEnabled() and $self->isProvisioned()) {
        # the certificate must be in place before haproxy restarts
        my $domain = $self->model('Configuration')->row()->printableValueByName('outgoingDomain');
        $self->_setCert($domain)
    }
}

sub _setApachePortsConf
{
    my ($self) = @_;

    my @params;
    push (@params, bindAddress => '0.0.0.0');
    # TODO: unhardcode this
    push (@params, port        => 80);
    push (@params, sslPort     => 443);

    $self->writeConfFile(APACHE_PORTS_FILE, "openchange/apache-ports.conf.mas", \@params);
}

sub _setSOGoApacheConf
{
    my ($self) = @_;

    # FIXME: do this only if webmail checkbox is enabled
    if ($self->isEnabled()) {
        my $global = $self->global();
        my $sysinfoMod = $global->modInstance('sysinfo');
        my @params = ();
        push (@params, hostname => $sysinfoMod->fqdn());

        my $webserverMod = $global->modInstance('webserver');
        # FIXME: unhardcode this
        push (@params, sslPort  => 443);

        if (-f OCSMANAGER_DOMAIN_PEM) {
            push (@params, sslCert => OCSMANAGER_DOMAIN_PEM);
        }

        $self->writeConfFile(SOGO_APACHE_CONF, "openchange/apache-sogo.mas", \@params);
        try {
            EBox::Sudo::root("a2enconf sogo");
        } catch (EBox::Exceptions::Sudo::Command $e) {
            # Already enabled?
            if ($e->exitValue() != 1) {
                $e->throw();
            }
        }
    } else {
        try {
            EBox::Sudo::root("a2disconf sogo");
        } catch (EBox::Exceptions::Sudo::Command $e) {
            # Already disabled?
            if ($e->exitValue() != 1) {
                $e->throw();
            }
        }
    }

    # Force apache restart to refresh the new sogo configuration
    EBox::Sudo::root('service apache2 restart');
}

sub _setupActiveSync
{
    my ($self) = @_;

    my $enabled = (-f '/etc/apache2/conf-enabled/zentyal-activesync.conf');
    my $enable = $self->_activesyncEnabled();
    if ($enable) {
        EBox::Sudo::root('a2enconf zentyal-activesync');
    } else {
        EBox::Sudo::silentRoot('a2disconf zentyal-activesync');
    }
    if ($enabled xor $enable) {
        my $global = $self->global();
        if ($global->modExists('sogo')) {
            $global->addModuleToPostSave('sogo');
        }
    }
}

sub _writeCronFile
{
    my ($self) = @_;

    my $cronfile = '/etc/cron.d/zentyal-openchange';
    if ($self->isEnabled()) {
        my $checkScript = '/usr/share/zentyal-openchange/check_oc.py';
        my $crontab = "* * * * * root $checkScript || /sbin/restart samba-ad-dc";
        EBox::Sudo::root("echo '$crontab' > $cronfile");
    } else {
        EBox::Sudo::root("rm -f $cronfile");
    }
}

sub _writeNotificationServiceConf
{
    my ($self) = @_;

    unless (EBox::Sudo::fileTest('-d', OC_NOTIF_SERVICE_CONF_PATH)) {
        EBox::Sudo::root("mkdir '" . OC_NOTIF_SERVICE_CONF_PATH . "'");
    }
    my $array = [];
    push (@{$array}, user => EBox::Config::configkey('oc_notif_broker_user'));
    push (@{$array}, pass => EBox::Config::configkey('oc_notif_broker_pass'));
    push (@{$array}, host => EBox::Config::configkey('oc_notif_broker_host'));
    push (@{$array}, port => EBox::Config::configkey('oc_notif_broker_port'));
    push (@{$array}, vhost => EBox::Config::configkey('oc_notif_broker_vhost'));
    push (@{$array}, exchange => EBox::Config::configkey('oc_notif_exchange'));
    push (@{$array}, newMailRouting => EBox::Config::configkey('oc_notif_new_mail_routing_key'));
    push (@{$array}, newMailQueue   => EBox::Config::configkey('oc_notif_new_mail_queue'));

    $self->writeConfFile(OC_NOTIF_SERVICE_CONF_FILE,
        'openchange/notification-service.cfg.mas',
        $array, { uid => 0, gid => 0, mode => '640' });
}

sub _writeSOGoDefaultFile
{
    my ($self) = @_;

    my $array = [];
    my $prefork = EBox::Config::configkey('sogod_prefork');
    unless (length $prefork) {
        $prefork = SOGO_DEFAULT_PREFORK;
    }
    push (@{$array}, prefork => $prefork);
    $self->writeConfFile(SOGO_DEFAULT_FILE,
        'openchange/sogo.mas',
        $array, { uid => 0, gid => 0, mode => '755' });
}

sub _writeSOGoConfFile
{
    my ($self) = @_;

    my $array = [];

    my $sysinfo = $self->global->modInstance('sysinfo');
    my $timezoneModel = $sysinfo->model('TimeZone');
    my $sogoTimeZone = $timezoneModel->row->printableValueByName('timezone');

    my $users = $self->global->modInstance('samba');
    my $dcHostName = $users->ldap()->rootDse->get_value('dnsHostName');
    my (undef, $sogoMailDomain) = split (/\./, $dcHostName, 2);

    push (@{$array}, sogoPort => SOGO_PORT);
    push (@{$array}, sogoLogFile => SOGO_LOG_FILE);
    push (@{$array}, sogoPidFile => SOGO_PID_FILE);
    push (@{$array}, sogoTimeZone => $sogoTimeZone);
    push (@{$array}, sogoMailDomain => $sogoMailDomain);

    my $mail = $self->global->modInstance('mail');
    my $retrievalServices = $mail->model('RetrievalServices');
    my $sieveEnabled = $retrievalServices->value('managesieve');
    my $sieveServer = ($sieveEnabled ? 'sieve://127.0.0.1:4190' : '');
    my $imapServer = '127.0.0.1:143';
    my $smtpServer = '127.0.0.1:25';
    push (@{$array}, imapServer => $imapServer);
    push (@{$array}, smtpServer => $smtpServer);
    push (@{$array}, sieveServer => $sieveServer);

    my $dbName = $self->_sogoDbName();
    my $dbUser = $self->_sogoDbUser();
    my $dbPass = $self->_sogoDbPass();
    push (@{$array}, dbName => $dbName);
    push (@{$array}, dbUser => $dbUser);
    push (@{$array}, dbPass => $dbPass);
    push (@{$array}, dbHost => '127.0.0.1');
    push (@{$array}, dbPort => 3306);

    my $baseDN = $self->ldap->dn();
    if (EBox::Config::boolean('openchange_disable_multiou')) {
        $baseDN = "ou=Users,$baseDN";
    }

    push (@{$array}, sambaBaseDN => $users->ldap()->dn());
    push (@{$array}, sambaBindDN => $self->_kerberosServiceAccountDN());
    push (@{$array}, sambaBindPwd => $self->_kerberosServiceAccountPassword());
    push (@{$array}, sambaHost => "ldap://127.0.0.1"); #FIXME? not working using $users->ldap()->url()

    my (undef, undef, undef, $gid) = getpwnam('sogo');
    $self->writeConfFile(SOGO_CONF_FILE,
        'openchange/sogo.conf.mas',
        $array, { uid => 0, gid => $gid, mode => '640' });
}

# Configure OCSManager which is in charge of EWS such as:
#  * Autodiscover
#  * Availability (Free/Busy)
#  * Out of Office
sub _setOCSManagerConf
{
    my ($self) = @_;

    my $global  = $self->global();
    my $sysinfo = $global->modInstance('sysinfo');
    my $users   = $global->modInstance('samba');
    my $mail    = $global->modInstance('mail');
    my $domain =   $self->model('Configuration')->row()->printableValueByName('outgoingDomain');
    my $adminMail = $mail->model('SMTPOptions')->value('postmasterAddress');
    if ($adminMail eq 'postmasterRoot') {
        $adminMail = 'postmaster@' . $domain;
    }
    my $confFileParams = [
        bindDn       => $self->_kerberosServiceAccountDN(),
        bindPwd      => $self->_kerberosServiceAccountPassword(),
        baseDn       => 'CN=Users,' . $users->ldap()->dn(),
        port         => 389,
        adminMail    => $adminMail,
        rpcProxy     => $self->_rpcProxyEnabled(),
        rpcProxySSL  => ($self->_rpcProxyEnabled() and $self->model('RPCProxy')->httpsEnabled()),
        mailboxesDir => EBox::Mail::VDOMAINS_MAILBOXES_DIR(),
    ];
    if ($self->_rpcProxyEnabled()) {
        my $externalHostname;
        try {
            $externalHostname = $self->rpcProxyHosts()->[0];
            push (@{$confFileParams}, rpcProxyExternalHostname => $externalHostname);
        } catch ($ex) {
            EBox::error("Error getting hostname for RPC proxy: $ex");
        }
        my $network = $global->modInstance('network');
        push(@{$confFileParams}, intNetworks => $network->internalNetworks());
    }

    $self->writeConfFile(OCSMANAGER_CONF_FILE,
                         'openchange/ocsmanager.ini.mas',
                         $confFileParams,
                         { uid => 0, gid => 0, mode => '640' }
                        );


    my $confDir = EBox::Config::conf() . 'openchange';
    EBox::Sudo::root("mkdir -p '$confDir'");

    if ($self->isEnabled()) {
        if ($self->isProvisioned()) {
            $self->_setCert($domain);
            my $incParams = [
                domain => $domain
            ];
            $self->writeConfFile(OCSMANAGER_APACHE_CONF,
                                "openchange/apache-ocsmanager.conf.mas",
                                $incParams,
                                { uid => 0, gid => 0, mode => '644' }
            );
            try {
                EBox::Sudo::root("a2enconf zentyal-ocsmanager");
            } catch (EBox::Exceptions::Sudo::Command $e) {
                # Already enabled?
                if ($e->exitValue() != 1) {
                    $e->throw();
                }
            }
        }
    } else {
        try {
            EBox::Sudo::root("a2disconf zentyal-ocsmanager");
        } catch (EBox::Exceptions::Sudo::Command $e) {
            # Already disabled?
            if ($e->exitValue() != 1) {
                $e->throw();
            }
        }
    }
}

# Create the required certificates using zentyal-ca to run the following services:
#   * Autodiscover
#   * RPC/Proxy
#   * EWS
sub _setCert
{
    my ($self, $domain) = @_;

    my $ca = $self->global()->modInstance('ca');
    if (not $ca->isAvailable()) {
        EBox::error("Cannot create autodiscovery certificates because there is not usable CA");
        EBox::Sudo::root('rm -rf "' . OCSMANAGER_DOMAIN_PEM . '"');
        return;
    }

    my $caCert = $ca->getCACertificateMetadata();
    # Used for autodiscover, RPC/Proxy and EWS
    my $domainCert = $ca->getCertificateMetadata(cn => $domain);
    if (not $domainCert or ($domainCert->{state} ne 'V')) {
        my $rpcProxyHost;
        try {
            $rpcProxyHost = $self->_rpcProxyHostForDomain($domain);
        } catch (EBox::Exceptions::External $ex) {
            my $hostName = $self->global()->modInstance('sysinfo')->hostName();
            $rpcProxyHost = "${hostName}.$domain";
            EBox::warn("Using $rpcProxyHost as RPC proxy host");
        }
        $ca->issueCertificate(commonName => $domain,
                              endDate    => $caCert->{expiryDate},
                              subjAltNames => [ { type  => 'DNS',
                                                  value =>  $rpcProxyHost },
                                                { type  => 'DNS',
                                                  value => "autodiscover.${domain}" } ]);
    }

    my $metadata =  $ca->getCertificateMetadata(cn => $domain);
    if ($metadata->{state} eq 'V') {
        my $domainCrt = $metadata->{path};
        my $domainKey = $ca->getKeys($domain)->{privateKey};
        EBox::Sudo::root("cat $domainCrt $domainKey > " . OCSMANAGER_DOMAIN_PEM);
    } else {
        EBox::error("Certificate '$domain' not longer valid. Not using it for autodiscover");
        EBox::Sudo::root('rm -f ' . OCSMANAGER_DOMAIN_PEM);
    }
}

sub _setRPCProxyConf
{
    my ($self) = @_;

    my @cmds;
    # remove stock rpcproxy.conf file because it could interfere
    push (@cmds, 'rm -rf ' . RPCPROXY_STOCK_CONF_FILE);

    my $rpcProxyConfFile = '/etc/apache2/sites-available/zentyaloc-rpcproxy.conf';
    my @params = (
        rpcproxyAuthCacheDir => RPCPROXY_AUTH_CACHE_DIR,
    );

    $self->writeConfFile(
        $rpcProxyConfFile, 'openchange/apache-rpcproxy.conf.mas',
         \@params);

    if ($self->_rpcProxyEnabled()) {
        push (@cmds, 'mkdir -p ' . RPCPROXY_AUTH_CACHE_DIR);
        push (@cmds, 'chown -R www-data:www-data ' . RPCPROXY_AUTH_CACHE_DIR);
        push (@cmds, 'chmod 0750 ' . RPCPROXY_AUTH_CACHE_DIR);
        push (@cmds, 'a2ensite zentyaloc-rpcproxy');
    } else {
        push (@cmds, 'a2dissite zentyaloc-rpcproxy');
    }

    EBox::Sudo::root(@cmds);
}

sub _writeRewritePolicy
{
    my ($self) = @_;

    if ($self->isProvisioned()) {
        my $sysinfo = $self->global()->modInstance('sysinfo');
        my $defaultDomain = $sysinfo->hostDomain();

        my $rewriteDomain = $self->model('Configuration')->row()->printableValueByName('outgoingDomain');
        if (not $rewriteDomain) {
            $rewriteDomain = $defaultDomain;
        }

        my @rewriteParams;
        push @rewriteParams, ('defaultDomain' => $defaultDomain);
        push @rewriteParams, ('rewriteDomain' => $rewriteDomain);

        $self->writeConfFile(REWRITE_POLICY_FILE,
            'openchange/rewriteDomainPolicy.mas',
            \@rewriteParams, { uid => 0, gid => 0, mode => '644' });

        EBox::Sudo::root('/usr/sbin/postmap ' . REWRITE_POLICY_FILE);
    }
}

# Method: menu
#
#   Add an entry to the menu with this module.
#
sub menu
{
    my ($self, $root) = @_;

    my $folder = new EBox::Menu::Folder(
        'name' => 'Mail',
        'icon' => 'mail',
        'text' => __('Mail'),
        'tag' => 'main',
        'order' => 4
    );

    $folder->add(new EBox::Menu::Item(
        url => 'Mail/OpenChange',
        text => $self->printableName(),
        order => 3)
    );

    $root->add($folder);
}

sub _ldapModImplementation
{
    return new EBox::OpenChange::LdapUser();
}

# Method: isProvisioned
#
#     Return true if the OpenChange is provisioned in Samba + DBs.
#
#     It is independent from saving changes state
#
# Returns:
#
#     Boolean
#
sub isProvisioned
{
    my ($self) = @_;

    my $state = $self->get_state();
    my $provisioned = $state->{isProvisioned};
    if (defined $provisioned and $provisioned) {
        return 1;
    }
    return 0;
}

# Method: setProvisioned
#
#     Set the OpenChange whether OpenChange is provisioned in Samba +
#     DBs.
#
#     It is independent from saving changes state.
#
# Parameters:
#
#     provisioned - Boolean to set the provisioned state
#
sub setProvisioned
{
    my ($self, $provisioned) = @_;

    my $state = $self->get_state();
    $state->{isProvisioned} = $provisioned;
    $self->set_state($state);
}

sub _setupSOGoDatabase
{
    my ($self) = @_;

    my $dbUser = $self->_sogoDbUser();
    my $dbPass = $self->_sogoDbPass();
    my $dbName = $self->_sogoDbName();
    my $dbHost = '127.0.0.1';

    my $db = EBox::DBEngineFactory::DBEngine();
    $db->updateMysqlConf();
    $db->sqlAsSuperuser(sql => "CREATE DATABASE IF NOT EXISTS $dbName");
    $db->sqlAsSuperuser(sql => "GRANT ALL ON $dbName.* TO $dbUser\@$dbHost " .
                               "IDENTIFIED BY \"$dbPass\";");
    $db->sqlAsSuperuser(sql => 'flush privileges;');
}

sub _sogoDbName
{
    my ($self) = @_;

    return 'sogo';
}

sub _sogoDbUser
{
    my ($self) = @_;

    my $dbUser = EBox::Config::configkey('sogo_dbuser');
    return (length $dbUser > 0 ? $dbUser : 'sogo');
}

sub _sogoDbPass
{
    my ($self) = @_;

    # Return value if cached
    if (defined $self->{sogo_db_password}) {
        return $self->{sogo_db_password};
    }

    # Cache and return value if user configured
    my $dbPass = EBox::Config::configkey('sogo_dbpass');
    if (length $dbPass) {
        $self->{sogo_db_password} = $dbPass;
        return $dbPass;
    }

    # Otherwise, read from file
    my $path = EBox::Config::conf() . "sogo_db.passwd";

    # If file does not exists, generate random password and stash to file
    if (not -f $path) {
        my $generator = new String::Random();
        my $pass = $generator->randregex('\w\w\w\w\w\w\w\w');

        my ($login, $password, $uid, $gid) = getpwnam(EBox::Config::user());
        EBox::Module::Base::writeFile($path, $pass,
            { mode => '0600', uid => $uid, gid => $gid });
        $self->{sogo_db_password} = $pass;
        return $pass;
    }

    unless (defined ($self->{sogo_db_password})) {
        open (PASSWD, $path) or
            throw EBox::Exceptions::External('Could not get SOGo DB password');
        my $pwd = <PASSWD>;
        close (PASSWD);

        $pwd =~ s/[\n\r]//g;
        $self->{sogo_db_password} = $pwd;
    }

    return $self->{sogo_db_password};
}

# setup the dns to add autodiscover host
sub _setupDNS
{
    my ($self) = @_;
    my $sysinfo    = $self->global()->modInstance('sysinfo');
    my $hostDomain = $sysinfo->hostDomain();
    my $hostName   = $sysinfo->hostName();
    my $autodiscoverAlias = 'autodiscover';
    if ("$autodiscoverAlias.$hostName"  eq $hostDomain) {
        # strangely the hostname is already the autodiscover name
        return;
    }

    my $dns = $self->global()->modInstance('dns');

    my $domainRow = $dns->model('DomainTable')->find(domain => $hostDomain);
    if (not $domainRow) {
        throw EBox::Exceptions::External(
            __x("The expected domain '{d}' could not be found in the dns module",
                d => $hostDomain
               )
           );
    }

    my $hostRow = $domainRow->subModel('hostnames')->find(hostname => $hostName);
    if (not $hostRow) {
        throw EBox::Exceptions::External(
          __x("The required host record '{h}' could not be found in " .
              "the domain '{d}'.<br/>",
              h => $hostName,
              d => $hostDomain
             )
         );
    }

    my $aliasModel = $hostRow->subModel('alias');
    if ($aliasModel->find(alias => $autodiscoverAlias)) {
        # already added, nothing to do
        return;
    }
    # add the autodiscover alias
    $aliasModel->addRow(alias => $autodiscoverAlias);
}


# Method: configurationContainer
#
#   Return the ExchConfigurationContainer object that models the msExchConfigurationConainer entry for this
#   installation.
#
# Returns:
#
#   EBox::OpenChange::ExchConfigurationContainer object.
#
sub configurationContainer
{
    my ($self) = @_;

    my $usersMod = $self->global->modInstance('samba');
    unless ($usersMod->isEnabled() and $usersMod->isProvisioned()) {
        return undef;
    }
    my $defaultNC = $usersMod->ldap()->dn();
    my $dn = "CN=Microsoft Exchange,CN=Services,CN=Configuration,$defaultNC";

    my $object = new EBox::OpenChange::ExchConfigurationContainer(dn => $dn);
    if ($object->exists) {
        return $object;
    } else {
        return undef;
    }
}

# Method: organizations
#
#   Return a list of ExchOrganizationContainer objects that belong to this installation.
#
# Returns:
#
#   An array reference of ExchOrganizationContainer objects.
#
sub organizations
{
    my ($self) = @_;

    my $list = [];
    my $usersMod = $self->global->modInstance('samba');
    my $configurationContainer = $self->configurationContainer();

    return $list unless ($configurationContainer);

    my $params = {
        base => $configurationContainer->dn(),
        scope => 'one',
        filter => '(objectclass=msExchOrganizationContainer)',
        attrs => ['*'],
    };
    my $result = $usersMod->ldap()->search($params);
    foreach my $entry ($result->sorted('cn')) {
        my $organization = new EBox::OpenChange::ExchOrganizationContainer(entry => $entry);
        push (@{$list}, $organization);
    }

    return $list;
}
sub _rpcProxyHostForDomain
{
    my ($self, $domain) = @_;
    my $dns = $self->global()->modInstance('dns');
    my $domainExists = grep { $_->{name} eq $domain } @{ $dns->domains() };
    if (not $domainExists) {
        throw EBox::Exceptions::External(__x('Domain {dom} not configured in {oh}DNS module{ch}',
                                             dom => $domain,
                                             oh => '<a href="/DNS/Composite/Global">',
                                             ch => '</a>'
                                            ));
    }
    my @hosts = @{ $dns->getHostnames($domain) };

    my @ips;
    my $network = $self->global()->modInstance('network');
    my @extIfaces  = @{ $network->ExternalIfaces() };
    if (not @extIfaces) {
        throw EBox::Exceptions::External (__('System needs at least one external interface'));
    }
    foreach my $iface (@extIfaces) {
        my $addresses = $network->ifaceAddresses($iface);
        push @ips, map { $_->{address} } @{  $addresses };
    }

    my $matchedHost;
    my $matchedHostMatchs = 0;
    foreach my $host (@hosts) {
        my $matches = 0;
        foreach my $hostIp (@{ $host->{ip} }) {
            foreach my $ip (@ips) {
                if ($hostIp eq $ip) {
                    $matches += 1;
                    last;
                }
            }
            if ($matches > $matchedHostMatchs) {
                $matchedHost = $host->{name};
                $matchedHostMatchs = $matches;
                if (@ips == $matchedHostMatchs) {
                    last;
                }
            }
        }
    }

    if (not $matchedHost) {
        EBox::Exceptions::External->throw(__x('Cannot find any host in {oh}DNS domain {dom}{ch} which corresponds to your external IP addresses',
                                              dom => $domain,
                                              oh => '<a href="/DNS/Composite/Global">',
                                              ch => '</a>'
                                             ));
    }
    return $matchedHost . '.' . $domain;
}

sub _activesyncEnabled
{
    my ($self) = @_;
    return $self->model('Configuration')->value('activesync');
}

sub _rpcProxyDomain
{
    my ($self) = @_;
    return $self->model('Configuration')->row()->printableValueByName('outgoingDomain');
}

# Method: rpcProxyHosts
#
# Returns:
#
#     Array ref - Return the valid RPC/Proxy hosts.
#                 It calculates the hostname and the domain to use.
#
sub rpcProxyHosts
{
    my ($self) = @_;
    my @hosts;
    my $domain = $self->_rpcProxyDomain();
    if (not $domain) {
        throw EBox::Exceptions::External(__('No outgoing mail domain configured'));
    }
    push @hosts, $self->_rpcProxyHostForDomain($domain);
    push @hosts, $domain;
    return \@hosts;
}

sub _vdomainModImplementation
{
    my ($self) = @_;
    return EBox::OpenChange::VDomainsLdap->new($self);
}

# Method: _getPassword
#
#   Read a password file (one line, contents chomped) as root
#
sub _getPassword
{
    my ($self, $path, $target) = @_;

    try {
        my ($pwd) = @{EBox::Sudo::root("cat \"$path\"")};
        $pwd =~ s/[\n\r]//g;
        return $pwd;
    } catch($ex) {
        EBox::error("Error trying to read $path '$ex'");
        throw EBox::Exceptions::Internal("Could not open $path to get $target password.");
    };
}

# Method: getImapMasterPassword
#
#   We can login as any user on imap server with this, the first time
#   this method is called a new password will be generated and put it
#   on a file inside samba private directory (SOGo will look for this
#   password there)
#
# Returns:
#
#   Password to use as master password for imap server. We can login
#   as any user with this.
#
sub getImapMasterPassword
{
    my ($self) = @_;

    unless (EBox::Sudo::fileTest('-e', OPENCHANGE_IMAP_PASSWD_FILE)) {
        # Generate password file
        EBox::debug("Generating imap master password file");
        my $parentDir = dirname(OPENCHANGE_IMAP_PASSWD_FILE);
        EBox::Sudo::root("mkdir -p -m700 '$parentDir'");
        my $generator = new String::Random();
        my $pass = $generator->randregex('\w\w\w\w\w\w\w\w');
        EBox::Module::Base::writeFile(OPENCHANGE_IMAP_PASSWD_FILE,
            "$pass", { mode => '0640', uid => 'root', gid => 'ebox' });
    }

    return $self->_getPassword(OPENCHANGE_IMAP_PASSWD_FILE, "Imap master");
}

# Method: isProvisionedWithMySQL
#
#   Since Zentyal 3.4 MySQL backends are the default ones but on previous
#   versions they didn't exist.
#
# Returns:
#
#   Whether OpenChange module has been provisioned using MySQL backends or not.
#
sub isProvisionedWithMySQL
{
    my ($self) = @_;

    return ($self->isProvisioned() and (-e OPENCHANGE_MYSQL_PASSWD_FILE));
}

# Method: connectionString
#
#   Get a connection string to be used for the different configurable backends of
#   OpenChange: named properties, openchangedb and indexing.
#
#   Currently MySQL is used as backend, the first time this method is called an
#   openchange user will be created
#
# Returns:
#
#   string with the following format schema://user:password@host/table, schema will
#   be, normally, mysql (because is the only one supported right now)
#
sub connectionString
{
    my ($self) = @_;

    unless (-e OPENCHANGE_MYSQL_PASSWD_FILE) {
        EBox::Sudo::root(EBox::Config::scripts('openchange') .
                'generate-database');
    }

    my $pwd = $self->_getPassword(OPENCHANGE_MYSQL_PASSWD_FILE, "Openchange MySQL");

    return "mysql://openchange:$pwd\@localhost/openchange";
}

# EBox::CA::Observer methods

sub certificateRevoked
{
    my ($self, $commonName, $isCACert) = @_;

    if ($self->isProvisioned()) {
        if ($isCACert) {
            return 1;
        }
        my $domain = $self->model('Configuration')->row()->printableValueByName('outgoingDomain');
        if ($commonName eq $domain) {
            return 1;
        }
    }
    return 0;
}

sub certificateRenewed
{
    my ($self, $commonName, $isCACert) = @_;
    $self->_certificateChanges($commonName, $isCACert);
}

sub freeCertificate
{
    my ($self, $commonName) = @_;
    $self->_certificateChanges($commonName);
}

sub _certificateChanges
{
    my ($self, $commonName, $isCACert) = @_;
    if ($isCACert) {
        $self->setAsChanged(1);
        EBox::Sudo::root('rm -rf "' . OCSMANAGER_DOMAIN_PEM . '"');
        return;
    }

    my $domain = $self->model('Configuration')->row()->printableValueByName('outgoingDomain');
    if ($commonName eq $domain) {
        $self->setAsChanged(1);
        EBox::Sudo::root('rm -f ' . OCSMANAGER_DOMAIN_PEM);
    }
}

sub _kerberosServicePrincipals
{
    return undef;
}

sub _kerberosKeytab
{
    return undef;
}


# Method: cleanForReprovision
#
# Overriden to remove also status of openchange provision and configuration
# related with mail virtual domains, because they can change after reprovision
sub cleanForReprovision
{
    my ($self) = @_;

    my $state = $self->get_state();
    delete $state->{'_schemasAdded'};
    delete $state->{'_ldapSetup'};
    delete $state->{'Provision'};
    delete $state->{'isProvisioned'};
    $self->set_state($state);

    $self->dropSOGODB();

    my @modelsToClean = qw(Provision RPCProxy Configuration);
    foreach my $name (@modelsToClean) {
        $self->model($name)->removeAll(1);
    }

    # remove rpcproxy certificates
    for my $certFile ((OCSMANAGER_DOMAIN_PEM)) {
        EBox::Sudo::root("rm -f '$certFile'");
    }

    $self->setAsChanged(1);
}

sub dropSOGODB
{
    my ($self) = @_;

    if ($self->isProvisionedWithMySQL()) {
        # It removes the file with mysql password and the user from mysql
        EBox::Sudo::root(EBox::Config::scripts('openchange') .
              'remove-database');
    }

    # Drop SOGo database and db user. To avoid error if it does not exists,
    # the user is created and granted harmless privileges before drop it
    my $db = EBox::DBEngineFactory::DBEngine();
    my $dbName = $self->_sogoDbName();
    my $dbUser = $self->_sogoDbUser();
    $db->sqlAsSuperuser(sql => "DROP DATABASE IF EXISTS $dbName");
    $db->sqlAsSuperuser(sql => "GRANT USAGE ON *.* TO $dbUser");
    $db->sqlAsSuperuser(sql => "DROP USER $dbUser");
}

sub wizardPages
{
    my ($self) = @_;

    my $samba = $self->global()->modInstance('samba');
    return [] if $samba->_adcMode();

    my $mail = $self->global()->modInstance('mail');
    return [] if ($mail->model('VDomains')->size() == 0);

    return [{ page => '/OpenChange/Wizard/Provision', order => 410 }];
}


1;
