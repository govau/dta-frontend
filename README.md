## DTA Frontend BOSH Release

This is a HAProxy BOSH release designed as a highly available reverse proxy for a multi-tenant site hosted by the Australian Digital Transformation Agency.

### Features

* Is reconfigurable at runtime (including HTTPS certificates) without redeployment
* Supports graceful restart with draining of connections
* Supports server tuning with sysctl and hardening with iptables firewall
* Designed with ACME-based automated HTTPS certificate management in mind
* Designed for integration with testing pipelines

[An example Concourse pipeline](https://github.com/govau/cga-frontend-config) that tests and deploys releases is also available.

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

A reload of configuration is triggered by running `/var/vcap/jobs/haproxy/bin/update` (see [the source](jobs/haproxy/templates/update) for usage details), which can be run using BOSH's SSH support.  (More sophisticated remote management functionality is expected to be added in future.)

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
            http-request redirect location http://"${FE_ACME_ADDRESS}"%[capture.req.uri] code 302 if acme_challenge
            http-request redirect scheme https code 301 unless acme_challenge
      # Optionally add some extra variables that can be used in the HAProxy configs
      # It's recommended (but not required) to give them a common prefix for easy whitelisting in test environments
      env:
        FE_ACME_ADDRESS: acme.example.com
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
