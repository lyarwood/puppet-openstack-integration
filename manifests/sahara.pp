# Configure the Sahara service
#
# [*integration_enable*]
#   (optional) Boolean to run integration tests.
#   Defaults to true.
#
class openstack_integration::sahara (
  $integration_enable = true,
){

  include ::openstack_integration::config
  include ::openstack_integration::params

  if $::openstack_integration::config::ssl {
    openstack_integration::ssl_key { 'sahara':
      notify  => Service['httpd'],
      require => Package['sahara-api'],
    }
    Exec['update-ca-certificates'] ~> Service['httpd']
  }

  openstack_integration::mq_user { 'sahara':
    password => 'an_even_bigger_secret',
    before   => Anchor['sahara::service::begin'],
  }

  class { '::sahara::db::mysql':
    password => 'sahara',
  }

  class { '::sahara::keystone::auth':
    public_url   => "${::openstack_integration::config::base_url}:8386/v1.1/%(tenant_id)s",
    internal_url => "${::openstack_integration::config::base_url}:8386/v1.1/%(tenant_id)s",
    admin_url    => "${::openstack_integration::config::base_url}:8386/v1.1/%(tenant_id)s",
    password     => 'a_big_secret',
  }
  class { '::sahara':
    host                  => $::openstack_integration::config::host,
    database_connection   => 'mysql+pymysql://sahara:sahara@127.0.0.1/sahara?charset=utf8',
    use_ssl               => $::openstack_integration::config::ssl,
    cert_file             => $::openstack_integration::params::cert_path,
    key_file              => "/etc/sahara/ssl/private/${::fqdn}.pem",
    default_transport_url => os_transport_url({
      'transport' => $::openstack_integration::config::messaging_default_proto,
      'host'      => $::openstack_integration::config::host,
      'port'      => $::openstack_integration::config::messaging_default_port,
      'username'  => 'sahara',
      'password'  => 'an_even_bigger_secret',
    }),
    rabbit_use_ssl        => $::openstack_integration::config::ssl,
    amqp_sasl_mechanisms  => 'PLAIN',
    debug                 => true,
  }
  class { '::sahara::keystone::authtoken':
    password             => 'a_big_secret',
    user_domain_name     => 'Default',
    project_domain_name  => 'Default',
    auth_url             => $::openstack_integration::config::keystone_admin_uri,
    www_authenticate_uri => $::openstack_integration::config::keystone_auth_uri,
    memcached_servers    => $::openstack_integration::config::memcached_servers,
  }
  $service_name = $::os_package_type ? {
    'debian' => $::sahara::params::api_service_name,
    default  => 'httpd',
  }
  class { '::sahara::service::api':
    service_name => $service_name,
  }
  if $service_name == 'httpd' {
    # NOTE(tobias-urdin): The sahara-api package in Ubuntu installs this apache vhosts which we
    # do not need since we create them using the puppetlabs-apache module. Set them as empty
    # so that package upgrades still work.
    if ($::operatingsystem == 'Ubuntu') and (versioncmp($::operatingsystemmajrelease, '18') >= 0) {
      ensure_resource('file', '/etc/apache2/sites-available/sahara-api.conf', {
        'ensure'  => 'present',
        'content' => '',
      })
      ensure_resource('file', '/etc/apache2/sites-enabled/sahara-api.conf', {
        'ensure'  => 'present',
        'content' => '',
      })

      Package['sahara-api'] -> File['/etc/apache2/sites-available/sahara-api.conf']
      -> File['/etc/apache2/sites-enabled/sahara-api.conf'] ~> Anchor['sahara::install::end']
    }

    include ::apache
    class { '::sahara::wsgi::apache':
      bind_host => $::openstack_integration::config::ip_for_url,
      ssl       => $::openstack_integration::config::ssl,
      ssl_key   => "/etc/sahara/ssl/private/${::fqdn}.pem",
      ssl_cert  => $::openstack_integration::params::cert_path,
      workers   => 2,
    }
  }
  class { '::sahara::service::engine': }
  class { '::sahara::client': }
  class { '::sahara::notify': }

  if $integration_enable {
    # create simple sahara templates
    sahara_node_group_template { 'master':
      ensure         => present,
      plugin         => 'vanilla',
      plugin_version => '2.7.1',
      flavor         => 'm1.micro',
      node_processes => [ 'namenode', 'resourcemanager' ],
    }

    sahara_node_group_template { 'worker':
      ensure         => present,
      plugin         => 'vanilla',
      plugin_version => '2.7.1',
      flavor         => 'm1.micro',
      node_processes => [ 'datanode', 'nodemanager' ],
    }

    sahara_cluster_template { 'cluster':
      ensure      => present,
      node_groups => [ 'master:1', 'worker:2' ]
    }

    Nova_flavor<||> -> Sahara_node_group_template<||>
    Class['::sahara::keystone::auth'] -> Sahara_node_group_template<||>
    Class['::openstack_extras::auth_file'] -> Sahara_node_group_template<||>
  }
}
