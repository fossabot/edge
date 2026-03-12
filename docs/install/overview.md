# Installation Overview

Fairvisor is distributed as container images and installed as infrastructure runtime.

## Official Install Profiles

- Kubernetes via Helm (`helm/fairvisor-edge`)
- VM/metal via `docker run` and `systemd`
- Local smoke testing via Docker Compose
- Troubleshooting guide (`docs/install/troubleshooting.md`)

## Artifacts

- Runtime image: `ghcr.io/fairvisor/fairvisor-edge:<version>`
- CLI image: `ghcr.io/fairvisor/fairvisor-cli:<version>`

## Configuration Modes

- SaaS mode: set `FAIRVISOR_SAAS_URL`, `FAIRVISOR_EDGE_ID`, `FAIRVISOR_EDGE_TOKEN`
- Standalone mode: mount a local policy bundle and set `FAIRVISOR_CONFIG_FILE`

Both modes are supported in production.

## GeoIP2 and ASN Database Setup

To enable geo-based and ASN-based rate limiting, Fairvisor requires MaxMind GeoLite2 (or equivalent) databases in `.mmdb` format.

### 1. Obtain databases
Download `GeoLite2-Country.mmdb` and `GeoLite2-ASN.mmdb` from MaxMind or a compatible source.

### 2. Mount databases to the container
Mount the directory containing the `.mmdb` files to `/etc/geoip2` in the Fairvisor container:

```bash
docker run -v /path/to/geoip-dbs:/etc/geoip2 ... ghcr.io/fairvisor/fairvisor-edge
```

The runtime will automatically detect the databases and reload them every 24 hours.

### 3. Verification
If the databases are missing, Nginx will fail to start. Ensure the worker process has read permissions for these files.
