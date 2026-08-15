# Local Tailscale on TrueNAS

Self-hosted [Headscale](https://headscale.net) (an open-source, self-hosted
implementation of the Tailscale coordination server) running on TrueNAS
SCALE via Docker Compose, fronted by Caddy for automatic HTTPS on your own
domain. Once it's up, your devices run the normal Tailscale client but point
at your own server instead of Tailscale's cloud service (`login.tailscale.com`).

```
Internet ── router (port-forward 80/443) ── TrueNAS SCALE
                                               └── docker compose
                                                     ├── caddy   (TLS termination, :80/:443)
                                                     └── headscale (:8080, internal only)
```

## Prerequisites

- TrueNAS SCALE with the Apps service (Docker/Kubernetes) enabled, and SSH
  access to it.
- A domain you control, with DNS managed somewhere you can add records
  (e.g. Cloudflare).
- Ability to port-forward 80/tcp and 443/tcp (and 443/udp for HTTP/3) from
  your router to your TrueNAS box.

## 1. DNS

Create an **A record** (and AAAA if you have IPv6) pointing a subdomain at
your home's public IP, e.g.:

```
headscale.yourdomain.com.   A   203.0.113.10
```

If you use Cloudflare, keep the record **DNS only** (grey cloud, not
proxied/orange) — Headscale's client protocol needs a direct TLS connection
to your server for Let's Encrypt's HTTP-01 challenge and for the Tailscale
client's noise-protocol handshake to work reliably.

Your public IP will change unless your ISP gives you a static one — use a
dynamic DNS updater (Cloudflare has a straightforward API for this) if it's
dynamic.

## 2. Get this repo onto TrueNAS

SSH into TrueNAS SCALE and clone this repo into a dataset, e.g.
`/mnt/<pool>/apps/headscale`:

```bash
cd /mnt/<pool>/apps
git clone <this-repo-url> headscale
cd headscale
```

## 3. Configure

```bash
cp .env.example .env
```

Edit `.env`:

```
HEADSCALE_DOMAIN=headscale.yourdomain.com
ACME_EMAIL=you@yourdomain.com
TZ=America/New_York
```

`docker-compose.yml` feeds `HEADSCALE_DOMAIN` into headscale as
`HEADSCALE_SERVER_URL` (headscale reads `HEADSCALE_*` env vars as config
overrides), so you generally don't need to hand-edit
`config/headscale/config.yaml` — it's provided as the underlying template
and for reference.

One thing worth setting deliberately: `dns.base_domain` in
`config/headscale/config.yaml`. This is the suffix MagicDNS gives your
devices (e.g. `laptop.base_domain`) and **must not** be the same as your
public `HEADSCALE_DOMAIN`/`server_url` host — pick something like
`ts.yourdomain.com` or a made-up internal suffix (default here is
`headscale.example.internal`). It doesn't need to resolve publicly.

## 4. Port forward

On your router, forward:
- TCP 80 → TrueNAS IP : 80
- TCP 443 → TrueNAS IP : 443
- UDP 443 → TrueNAS IP : 443 (optional, enables HTTP/3)

Caddy needs 80 briefly for the Let's Encrypt HTTP-01 challenge and to
redirect to HTTPS.

## 5. Deploy

Either via SSH:

```bash
docker compose up -d
docker compose logs -f caddy   # watch for successful cert issuance
```

...or as a TrueNAS SCALE **Custom App**: Apps → Discover Apps → *Custom App*
→ *Install via YAML*, and paste the contents of `docker-compose.yml` (set
`HEADSCALE_DOMAIN`/`ACME_EMAIL`/`TZ` directly in the YAML's `environment:`
blocks in that case, since the Custom App UI doesn't read `.env`).

Once `caddy` logs show a certificate obtained, `https://headscale.yourdomain.com`
should load headscale's plain-text "healthy" style landing response.

## 6. Create a user and register a device

```bash
./scripts/create-user.sh myself
./scripts/create-preauthkey.sh myself --reusable --expiration 24h
```

Copy the printed key, then on any device with the Tailscale client:

```bash
tailscale up --login-server=https://headscale.yourdomain.com --authkey=<key>
```

Or, without a pre-auth key (interactive login):

```bash
tailscale up --login-server=https://headscale.yourdomain.com
```

This prints a URL — approve it with:

```bash
docker exec headscale headscale users list          # find your user
docker exec headscale headscale nodes register --user myself --key <nodekey-from-tailscale-up-output>
```

## 7. Access control (optional)

By default every device in every user can reach every other device. To
restrict this, write an ACL policy to `config/headscale/acl.hujson` and
uncomment the `policy:` block in `config/headscale/config.yaml`, then
`docker compose restart headscale`. See headscale's
[ACL docs](https://headscale.net/stable/ref/acls/) for syntax.

## Backups

```bash
./scripts/backup.sh
```

Tars up `config/headscale` (includes the noise private key — losing it
breaks every existing client) and `data/headscale` (the SQLite database)
into `backups/`. Run this before upgrades and on a schedule (e.g. a cron
job or a TrueNAS periodic snapshot task on the dataset).

## Updating headscale

Bump the image tag in `docker-compose.yml` (`headscale/headscale:X.Y.Z`),
check the [release notes](https://github.com/juanfont/headscale/releases)
for breaking config changes, back up first, then:

```bash
docker compose pull headscale
docker compose up -d headscale
```

Tailscale clients must stay within headscale's supported client version
range — check the release notes if `tailscale up` starts failing after an
upgrade.

## Troubleshooting

- **Caddy can't get a certificate**: confirm the A record resolves to your
  current public IP, ports 80/443 are actually forwarded (test from outside
  your network, e.g. a phone on cellular data), and Cloudflare proxying is
  off (grey cloud) for the record.
- **`tailscale up` connects but nothing routes**: check
  `docker exec headscale headscale nodes list` — the node needs to show as
  registered and online.
- **Changed `dns.base_domain` after devices already joined**: existing
  devices need `tailscale up` re-run to pick up the new MagicDNS suffix.
