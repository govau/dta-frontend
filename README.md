## DTA Frontend BOSH Release

This is a [HAProxy](https://www.haproxy.org/) 1.7.9 BOSH release designed as a highly available reverse proxy for a multi-tenant site hosted by the [Australian Digital Transformation Agency (DTA)](https://www.dta.gov.au/).

### Features

* Is reconfigurable at runtime (including HTTPS certificates) without redeployment
* Supports graceful restart with draining of connections
* Supports server tuning with sysctl and hardening with iptables firewall
* Designed with ACME-based automated HTTPS certificate management in mind
* Designed for integration with testing pipelines

[An example Concourse pipeline](https://github.com/govau/cga-frontend-config) that tests and deploys releases is also available.

### Why HAProxy?

[Nginx](https://nginx.org/en/) and [Lighttpd](https://www.lighttpd.net/) are both great web servers with good reverse proxying functionality, and are popular frontends to web applications.  However, HAProxy is more of a "do one thing and do it well" reverse proxy: it doesn't serve web pages, but has comprehensive support for HTTP/TCP proxying, request/response rewriting, access control, load balancing and backend management.  HAProxy is also better suited as a frontend to a multi-tenant server.  Nginx and Lighttpd are essentially configured site-by-site, which can lead to config boilerplate, or generate busy work as sites are added or removed.  HAProxy is configured as a collection of frontends, backends and proxying rules, so it's a more natural fit.

Major cloud providers are now offering layer 7 load balancers that can often do the job, too.  HAProxy has a highly flexible rule language that can easily be checked as-is into source control.  Sites that don't need the extra flexibility can use still use [Terraform](https://www.terraform.io/) for an infrastructure-as-code approach to managing cloud assets.

### Overview

The configuration is expected to be a tarball stored on a remote backend.  (Currently only AWS S3 supported.)  The tarball should unpack to a directory structure that's something like this:

(Minimal example)
```
.
└── haproxy.d
    └── config.cfg
```

(Production example)
```
.
├── certs
│   ├── foo.gov.au.pem
│   └── bar.gov.au.pem
├── dhparams.pem
├── haproxy.d
│   ├── config1.cfg
│   └── config2.cfg
├── iptables.conf
└── sysctl.d
    └── sysctl.conf
```

All files/directories are optional, except for `./haproxy.d`, which should contain [HAProxy configuration files](https://www.haproxy.org/download/1.7/doc/configuration.txt).  `./iptables.conf` (`iptables` configuration in [`iptables-save`](http://www.faqs.org/docs/iptables/iptables-save.html) format) and `./sysctl.d` (same as [`/etc/sysctl.d/`](http://man7.org/linux/man-pages/man5/sysctl.d.5.html)) are paths recognised by the BOSH release, but all other files/directories are just suggestions and can be added as needed.  The HAProxy configs can use the `HAPROXY_FILES_DIR` environment variable to get the path to the directory that contains the configuration files.  Extra custom environment variables can be added through the `env` job property.

See the [Highly Available Updates section](#highly-available-updates) for information on updating configuration.

### Example Manifest

```
---
name: frontend

releases:
- name: dta-frontend
  version: latest

instance_groups:
- name: frontend
  azs: [z1,z2,z3]
  instances: 3
  jobs:
  - name: haproxy
    properties:
      # This will load initial configuration from s3://my-config-bucket-name/config.tgz
      config_bucket: my-config-bucket-name
      default_config_object: config.tgz
      # If a config can't be loaded, this will be used instead.
      # (Useful for bootstrapping.)
      fallback_config: |
        frontend http
            mode http
            bind *:80
            acl acme_challenge path_beg -i /.well-known/acme-challenge/
            http-request redirect location http://"${FE_ACME_CLIENT_ADDRESS}"%[capture.req.uri] code 302 if acme_challenge
            http-request redirect scheme https code 301 unless acme_challenge

        listen healthcheck
            mode http
            bind *:9999
            server localhost:8080
      # Optionally add some extra variables that can be used in the HAProxy configs
      # It's recommended (but not required) to give them a common prefix for easy whitelisting in test environments
      env:
        FE_ACME_CLIENT_ADDRESS: acme.prod.example.com
      # Example drain command for a load balancer that only does TCP health checking
      drain_command: "disable frontend healthcheck"
      drain_seconds: 120
    release: dta-frontend
  vm_extensions: [frontend]  # Should add iam_instance_profile that gives access to above config bucket
  networks:
  - name: default
  stemcell: default
  vm_type: default

stemcells:
- alias: default
  os: ubuntu-trusty
  version: latest

update:
  canaries: 1
  canary_watch_time: 10000
  max_in_flight: 1
  update_watch_time: 10000
```

### Highly Available Updates

The configuration files for HAProxy and other things can be reloaded without doing a BOSH redeployment, which would trigger a full drain of each backend instance.  This is done by updating files in the config bucket and running `sudo /var/vcap/jobs/haproxy/bin/update` (see [the source](jobs/haproxy/templates/update) for usage details).  This can be done remotely by using BOSH's SSH support.  (More sophisticated remote management functionality is expected to be added in future.)  See [the example Concourse pipeline](https://github.com/govau/cga-frontend-config).

Other updates (such as updating stemcells, BOSH releases, or BOSH manifest properties) require a BOSH redeployment.  This BOSH release contains drain scripts to gracefully shut down each HAProxy instance as BOSH does its usual rolling restart.  You'll most likely need to configure the `drain_command` and `drain_seconds` properties to signal a drain to frontend load balancers.  The `drain_seconds` value should take into account the LB balancer health checking interval and the time-to-live (TTL) on any DNS records.  The `drain_command` is run immediately after BOSH starts a shutdown, then after `drain_seconds` HAProxy is signalled to do a soft shutdown.

Don't forget to also configure draining for backends.  For example, if using Cloud Foundry, you may need to change its [own drain wait time](https://github.com/cloudfoundry-incubator/routing-release/blob/develop/jobs/gorouter/spec#L62).
