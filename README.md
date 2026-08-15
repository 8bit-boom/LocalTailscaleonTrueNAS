# Local Tailscale on TrueNAS

Self-hosted [Headscale](https://headscale.net) (an open-source, self-hosted
implementation of the Tailscale coordination server) running on TrueNAS
SCALE via Docker Compose, fronted by Caddy for automatic HTTPS on your own
domain. Once it's up, your devices run the normal Tailscale client but point
at your own server instead of Tailscale's cloud service (`login.tailscale.com`).

```
Internet ── router (port-forward 80/443) ── TrueNAS SCALE
                                               └── docker compose
                                                     ├── caddy            (TLS termination, :80/:443)
                                                     │     ├─ HEADSCALE_DOMAIN       → headscale:8080
                                                     │     └─ HEADSCALE_ADMIN_DOMAIN → headscale-admin:80 (+ /api/* → headscale:8080)
                                                     ├── headscale        (:8080, internal only)
                                                     └── headscale-admin  (:80, internal only)
```

## Prerequisites

- TrueNAS SCALE with the Apps service (Docker/Kubernetes) enabled, and SSH
  access to it.
- A domain you control, with DNS managed somewhere you can add records
  (e.g. Cloudflare).
- Ability to port-forward 80/tcp and 443/tcp (and 443/udp for HTTP/3) from
  your router to your TrueNAS box.

## 1. DNS — creating the subdomains

This stack needs **two** subdomains pointed at your home's public IP: one
for headscale itself (`HEADSCALE_DOMAIN`) and one for the admin web UI
(`HEADSCALE_ADMIN_DOMAIN`). Steps below use Cloudflare; any DNS host works
the same way conceptually.

1. Log into the Cloudflare dashboard → select your domain (the zone, e.g.
   `yourdomain.com`) → **DNS** → **Records** → **Add record**.
2. First record — this is the one your dynamic-DNS updater (see below) will
   keep in sync, so make it the "real" one:
   - **Type**: `A`
   - **Name**: just the subdomain label, e.g. `headscale` (Cloudflare
     appends the zone automatically → `headscale.yourdomain.com`)
   - **IPv4 address**: your current public IP (check via `curl ifconfig.me`
     from inside your network, or "what's my ip" in a browser)
   - **Proxy status**: **DNS only** (grey cloud, not orange) — see the
     Cloudflare Tunnel note below for why this matters
   - Save.
3. Second record, for the admin UI — point it **at the first record**
   instead of duplicating the IP, using a `CNAME`:
   - **Type**: `CNAME`
   - **Name**: e.g. `headscale-admin`
   - **Target**: `headscale.yourdomain.com` (the record from step 2)
   - **Proxy status**: **DNS only**
   - Save.

   This way only one record needs updating when your IP changes — the
   CNAME just follows it. Add any future subdomains for this box the same
   way (CNAME → the step-2 record) instead of new A records.
4. Add matching `AAAA` records instead of/alongside the `A` record if your
   ISP gives you a routable IPv6 address.

> **Do not put Headscale behind Cloudflare Tunnel or the Cloudflare proxy,
> even if you already use a tunnel for other self-hosted services.**
> [Headscale's own docs](https://headscale.net/stable/ref/integration/reverse-proxy/)
> state this is unsupported: the Tailscale control protocol upgrades its
> WebSocket connection with `POST` instead of `GET`, which Cloudflare's edge
> rejects outright (see [headscale#2379](https://github.com/juanfont/headscale/issues/2379)).
> It's a protocol-level incompatibility, not a config issue — port-forwarding
> straight to Caddy (below) is the supported path. If you use Cloudflare
> Tunnel for other apps, that's unaffected — just don't route either of
> these two domains through it. (The admin UI's own traffic goes through
> Caddy too, for the same reason — see step 6.)

Your public IP will change unless your ISP gives you a static one — use a
dynamic DNS updater against the step-2 record (Cloudflare has a
straightforward API for this) if it's dynamic. DNS changes can take a few
minutes to propagate; `dig headscale.yourdomain.com` from another network
is the quickest way to check.

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
HEADSCALE_ADMIN_DOMAIN=headscale-admin.yourdomain.com
ACME_EMAIL=you@yourdomain.com
TZ=America/New_York
ADMIN_BASIC_AUTH_USER=admin
ADMIN_BASIC_AUTH_HASH=<generate this — see step 7 below>
```

Leave `ADMIN_ALLOWED_CIDRS` commented out unless your home network uses
something outside RFC1918 — the default in `docker-compose.yml` already
covers your tailnet's own range plus common private-LAN ranges.

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
`HEADSCALE_DOMAIN`/`HEADSCALE_ADMIN_DOMAIN`/`ACME_EMAIL`/`TZ`/
`ADMIN_BASIC_AUTH_USER`/`ADMIN_BASIC_AUTH_HASH` directly in the YAML's
`environment:` blocks in that case, since the Custom App UI doesn't read
`.env`). Generate `ADMIN_BASIC_AUTH_HASH` per step 7 below before deploying
— Caddy won't start the admin site correctly without it.

Once `caddy` logs show certificates obtained for both domains,
`https://headscale.yourdomain.com` should load headscale's plain-text
"healthy" style landing response.

## 6. Create a user and register a device

```bash
./scripts/create-user.sh myself
./scripts/create-preauthkey.sh myself --expiration 1h
```

This key is single-use and expires in an hour — generate a fresh one per
device rather than reaching for `--reusable` (a leaked reusable key admits
unlimited devices as `myself` for as long as it's valid).

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

## 7. Web admin UI (headscale-admin)

[headscale-admin](https://github.com/GoodiesHQ/headscale-admin) is a
browser-based UI for managing users, devices, and pre-auth keys, so you're
not stuck running `docker exec headscale headscale ...` for everything.
It's a static frontend — it holds no server-side state and talks to
headscale's REST API directly from your browser using an API key you
generate once and paste into its Settings page.

**Why this needs its own lock, beyond TLS:** headscale API keys are
unscoped — the same key that lets the UI list nodes can also create
users, mint pre-auth keys, and delete nodes. There's no read-only key.
And because `HEADSCALE_ADMIN_DOMAIN` gets a real Let's Encrypt certificate,
its hostname is published in public Certificate Transparency logs within
minutes — treat it as discoverable by internet scanners on day one, not
"security by an obscure name." So this domain is gated two ways before a
request ever reaches the app: an IP allowlist (`ADMIN_ALLOWED_CIDRS`, only
your tailnet + private LAN ranges by default) and HTTP basic auth on top
of that.

1. Generate the basic-auth credential:

   ```bash
   docker run --rm caddy:2.10-alpine caddy hash-password --plaintext 'something-long-and-random'
   ```

   Put the output in `.env` as `ADMIN_BASIC_AUTH_HASH` (and pick a
   username for `ADMIN_BASIC_AUTH_USER`, default `admin`). Restart Caddy
   to pick it up: `docker compose up -d caddy`.

2. Generate an API key:

   ```bash
   ./scripts/create-apikey.sh
   ```

   Copy the printed key — headscale never shows it again. It defaults to
   a 30-day expiration (see the script's own reminder for rotation
   steps). You can list key IDs and revoke early with
   `docker exec headscale headscale apikeys list` /
   `... apikeys expire --prefix <id>`.

3. Visit `https://headscale-admin.yourdomain.com` from a device on your
   home LAN or already on the tailnet (the IP allowlist blocks everyone
   else). If your router doesn't do NAT hairpinning for your own public
   domain, browse to the TrueNAS box's LAN IP directly instead while
   you're on that network. You'll hit the basic-auth prompt first (step 1
   above), then the app itself. Open **Settings** and enter:
   - **Headscale URL**: `https://headscale-admin.yourdomain.com` — i.e.
     the *admin* domain, not `HEADSCALE_DOMAIN`. Caddy proxies `/api/*` on
     the admin domain straight through to headscale (see the Caddyfile),
     so the browser's calls stay same-origin and never hit the browser's
     CORS restrictions or headscale's own domain directly.
   - **API Key**: the key from step 2.
4. You should now see your users/nodes. Re-run `create-preauthkey.sh` less
   often — you can generate pre-auth keys from the UI going forward.

Treat the API key like a root credential to headscale, and the basic-auth
password the same way — anyone with both can manage every user and
device. Rotate the API key on its 30-day cycle; rotate the basic-auth
password if you ever suspect it leaked (regenerate the hash, update
`.env`, `docker compose up -d caddy`).

Note: `config.yaml`'s `policy.mode` is set to `file` (see §8), so ACL
editing from within headscale-admin (if the version you're on offers it)
won't take effect — the huJSON file stays the source of truth, which is
deliberate so policy changes are reviewable/versioned rather than made
silently from a browser.

## 8. Access control

`config/headscale/acl.hujson` ships with a starter policy already wired up
via `policy.path` in `config.yaml` — by default it allows everything for a
`group:admins` containing the placeholder user `"myself"`. Before relying
on it:

1. Edit `config/headscale/acl.hujson` and replace `"myself"` with your
   real username(s) (whatever you passed to `create-user.sh`), and add
   more groups/rules as needed.
2. Apply the change and confirm it actually loaded — a policy file that
   fails to parse can leave headscale in an allow-all state, so treat a
   load error as an outage, not a warning:

   ```bash
   docker compose restart headscale
   docker compose logs headscale | grep -i polic
   docker exec headscale headscale policy get
   ```

headscale also supports a newer, more granular "grants" syntax alongside
the classic groups/tagOwners/acls format used here — see headscale's
[policy docs](https://headscale.net/stable/ref/policy/) if you need
per-capability rules instead of a simple allow-list.

## Backups

```bash
./scripts/backup.sh
```

Tars up `config/headscale` (includes the noise private key — losing it
breaks every existing client) and `data/headscale` (the SQLite database)
into `backups/`, taking a consistent DB snapshot first (headscale's
database has write-ahead logging on, so copying `db.sqlite` while it's
live can grab a torn snapshot otherwise). Keeps the 14 most recent
backups and prunes older ones. Run it before upgrades and on a schedule
(e.g. a cron job or a TrueNAS periodic snapshot task on the dataset) —
and periodically actually restore one into a scratch directory to confirm
it's usable, not just that the file exists.

The tarball is written `chmod 600` and contains the server's private key
and the full user/node/key database — copy it somewhere access-controlled
(not an SMB share everyone on the LAN can read) if you move it off-box,
and encrypt it for any off-site copy, e.g.
`gpg --symmetric --cipher-algo AES256 headscale-*.tar.gz`.

## Updating

**headscale / caddy / headscale-admin** are all pinned by tag *and*
digest in `docker-compose.yml` — `docker compose pull` alone won't change
what's running, on purpose (`headscale-admin` in particular runs
same-origin with the API and holds a bearer key in the browser, so
silently picking up unreviewed upstream changes is a real risk here, not
just a stability nicety). To upgrade a service deliberately:

1. Pick the new tag, read its release notes.
2. Resolve its digest, e.g. for headscale:
   ```bash
   docker manifest inspect headscale/headscale:X.Y.Z -v | grep -A2 '"digest"' | head -1
   ```
   (or `docker buildx imagetools inspect headscale/headscale:X.Y.Z` if you
   have buildx).
3. Update the `image:` line in `docker-compose.yml` to the new
   `tag@sha256:...`.
4. Back up first (above), then:
   ```bash
   docker compose pull headscale
   docker compose up -d headscale
   ```

For headscale specifically, Tailscale clients must stay within its
supported client version range — check the release notes if `tailscale up`
starts failing after an upgrade.

## Troubleshooting

- **Caddy can't get a certificate**: confirm the record resolves to your
  current public IP (`dig headscale.yourdomain.com` /
  `dig headscale-admin.yourdomain.com`), ports 80/443 are actually
  forwarded (test from outside your network, e.g. a phone on cellular
  data), and Cloudflare proxying is off (grey cloud) for both records.
- **`tailscale up` connects but nothing routes**: check
  `docker exec headscale headscale nodes list` — the node needs to show as
  registered and online.
- **Changed `dns.base_domain` after devices already joined**: existing
  devices need `tailscale up` re-run to pick up the new MagicDNS suffix.
- **headscale-admin shows a network/CORS error**: double check you entered
  the *admin* domain (not `HEADSCALE_DOMAIN`) as the Headscale URL in its
  Settings page — that's what makes its API calls same-origin through
  Caddy's `/api/*` route instead of cross-origin.
- **headscale-admin says the API key is invalid**: keys can expire (see
  `--expiration` on `create-apikey.sh`, 30d by default); generate a new
  one and update Settings.
- **Caddy won't start / admin site errors on load**: `ADMIN_BASIC_AUTH_HASH`
  is unset or malformed — Caddy's `basic_auth` directive needs a real
  bcrypt hash, not a blank value. Generate it per step 7 and re-deploy.
- **Can't reach the admin UI at all, even with the right URL**: you're
  outside `ADMIN_ALLOWED_CIDRS`. If you're on your home LAN and still
  blocked, your router likely doesn't NAT-hairpin your own public domain
  back to itself — browse to the TrueNAS box's LAN IP instead while
  you're on that network, or add your LAN's actual observed source range
  to `ADMIN_ALLOWED_CIDRS` in `.env`.
- **A container won't start after pulling this update**: `headscale` and
  `caddy` now run with a read-only root filesystem and a dropped
  capability set. If `headscale-admin` fails to start, check
  `docker compose logs headscale-admin` — its startup process may need a
  capability not in the `cap_add` list in `docker-compose.yml`; loosen
  that service's `cap_drop`/`cap_add` (or remove them) rather than the
  other two.

## Scope notes

A few things came up during a security review of this stack that are
worth knowing about even though they're not fixed here by default:

- **No rate limiting** on either public endpoint. Caddy has no built-in
  rate limiter; adding one means building a custom Caddy image with the
  [caddy-ratelimit](https://github.com/mholt/caddy-ratelimit) module via
  `xcaddy`, which trades a real DoS/brute-force mitigation for a build-time
  dependency and a knob that needs tuning against real Tailscale client
  traffic patterns (they're chatty — too tight a limit can lock out your
  own devices). Worth adding if this box gets probed a lot in practice;
  the IP allowlist + basic auth on the admin domain is the primary defense
  against brute force in the meantime, and `HEADSCALE_DOMAIN` is
  inherently open to any Tailscale client by design.
- **DERP relay and DNS both default to Tailscale Inc./Cloudflare
  infrastructure.** `dns.nameservers.global` in `config.yaml` points at
  Cloudflare (`1.1.1.1`); point it at a LAN resolver if you'd rather keep
  device DNS local. More notably, `config.yaml` has no `derp:` section, so
  node pairs that can't hole-punch relay through Tailscale's public DERP
  servers — encrypted, but metadata-visible to that infrastructure, which
  runs a little counter to self-hosting in the first place. Headscale can
  run its own embedded DERP server instead; it's not enabled by default
  here because it opens another public UDP port (3478) and is a deliberate
  tradeoff, not a drop-in default.
- **`docker exec` in every helper script is host-root-equivalent** —
  membership in the `docker` group on TrueNAS is effectively root on the
  box. Not a defect, just worth knowing before handing these scripts (or
  `docker` group membership) to anyone else.
