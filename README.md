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
                                                     │     ├─ HEADSCALE_ADMIN_DOMAIN → headscale-admin:80 (+ /api/* → headscale:8080)
                                                     │     └─ AUTHELIA_DOMAIN        → authelia:9091           [optional, "2fa" profile]
                                                     ├── headscale        (:8080, internal only)
                                                     ├── headscale-admin  (:80, internal only)
                                                     └── authelia         (:9091, internal only)     [optional, "2fa" profile]
```

## Quick start

```bash
ssh you@truenas
cd /mnt/<pool>/apps && git clone <this-repo-url> headscale && cd headscale
./scripts/setup.sh
```

That's the whole install for most people. The wizard asks about 9
questions (accepting every default is usually 3 real answers — your
domain, an email, and a username), then it:

- auto-detects your public IP, LAN IP, timezone, and whether ports 80/443
  are already taken (offering alternates if TrueNAS's own UI owns them);
- generates `.env`, hashes your admin password (never touching disk or
  shell history in plaintext), and substitutes your username into the ACL
  policy — no files to hand-edit;
- prints the exact DNS records to create, then checks them for you over
  public DNS before going further (including a specific diagnosis if a
  record is still routed through Cloudflare's proxy, which breaks Headscale
  — see below);
- brings the stack up against Let's Encrypt's **staging** CA first, so a
  DNS or port-forwarding mistake costs you nothing — production rate limits
  only get spent once staging succeeds;
- creates your first headscale user, confirms the ACL policy actually
  loaded, mints an API key and a one-hour pre-auth key, and prints a
  one-time summary card with everything you need, including the exact
  `tailscale up` command for your first device.

Prefer TrueNAS's **Custom App → Install via YAML** installer over SSH
access? Answer "no" when the wizard asks whether to deploy now (or pass
`--skip-deploy`) — it still generates everything, including a ready-to-paste
`truenas-custom-app.rendered.yaml` (see [below](#truenas-custom-app-yaml)).

Something not working? `./scripts/doctor.sh` re-checks everything the
wizard checked, any time, without changing anything — see
[Troubleshooting](#troubleshooting).

**What the wizard can't do for you:** create DNS records at your registrar,
or forward ports on your router — those happen outside this machine, so
there's no way around doing them yourself. It tells you exactly what to do
and verifies the result, which is most of the value; see
[DNS and port-forwarding](#dns-and-port-forwarding) for what's actually
involved and why.

The rest of this README is reference material: what the wizard sets up and
why, how to do any of it by hand if you'd rather, and how to operate the
stack afterwards (add devices, tighten the ACL, add 2FA, back up, update).

## Prerequisites

- TrueNAS SCALE with the Apps service (Docker/Kubernetes) enabled, and SSH
  access to it.
- A domain you control, with DNS managed somewhere you can add records
  (e.g. Cloudflare).
- Ability to port-forward 80/tcp and 443/tcp (and 443/udp for HTTP/3) from
  your router to your TrueNAS box.

## DNS and port-forwarding

The wizard prints the exact records to create and checks them for you, but
someone still has to click the buttons at your DNS provider and router —
here's what that actually involves and why it's shaped this way.

This stack needs **two** subdomains pointed at your home's public IP: one
for headscale itself (`HEADSCALE_DOMAIN`) and one for the admin web UI
(`HEADSCALE_ADMIN_DOMAIN`). Using Cloudflare as an example (any DNS host
works the same way conceptually):

1. Log into the Cloudflare dashboard → select your domain (the zone, e.g.
   `yourdomain.com`) → **DNS** → **Records** → **Add record**.
2. First record — this is the one your dynamic-DNS updater (see below) will
   keep in sync, so make it the "real" one:
   - **Type**: `A`
   - **Name**: just the subdomain label, e.g. `headscale` (Cloudflare
     appends the zone automatically → `headscale.yourdomain.com`)
   - **IPv4 address**: your current public IP (the wizard prints this; or
     check via `curl ifconfig.me` from inside your network)
   - **Proxy status**: **DNS only** (grey cloud, not orange) — see below
     for why this matters
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
> straight to Caddy is the supported path. If you use Cloudflare Tunnel for
> other apps, that's unaffected — just don't route either of these two
> domains through it. (The admin UI's own traffic goes through Caddy too,
> for the same reason.)

Your public IP will change unless your ISP gives you a static one — use a
dynamic DNS updater against the step-2 record (Cloudflare has a
straightforward API for this) if it's dynamic. DNS changes can take a few
minutes to propagate; the wizard's DNS check (or `./scripts/doctor.sh`)
loops so you can just wait and recheck.

**Port forward**, on your router:
- TCP 80 → TrueNAS IP : 80 (or your `HOST_HTTP_PORT`, if the wizard set one)
- TCP 443 → TrueNAS IP : 443 (or `HOST_HTTPS_PORT`)
- UDP 443 → same, optional, enables HTTP/3

Caddy needs 80 briefly for the Let's Encrypt HTTP-01 challenge and to
redirect to HTTPS.

## Doing any of this by hand

Everything below is what `./scripts/setup.sh` automates. You don't need to
read it to use the wizard — it's here for anyone who'd rather configure by
hand, wants to understand exactly what got generated, or is troubleshooting
something the wizard's own checks didn't catch.

### `.env`

```bash
cp .env.example .env
```

See the comments in `.env.example` for what each value does.
`docker-compose.yml` feeds `HEADSCALE_DOMAIN` into headscale as
`HEADSCALE_SERVER_URL` (headscale reads `HEADSCALE_*` env vars as config
overrides), so `config/headscale/config.yaml` doesn't need editing for that
part.

One thing worth setting deliberately: `dns.base_domain` in
`config/headscale/config.yaml`. This is the suffix MagicDNS gives your
devices (e.g. `laptop.base_domain`) and **must not** be the same as your
public `HEADSCALE_DOMAIN`/`server_url` host — pick something like
`ts.yourdomain.com` or a made-up internal suffix (default in the file is
`headscale.example.internal`). It doesn't need to resolve publicly.

Generate `ADMIN_BASIC_AUTH_HASH` (the wizard does this over stdin, so the
plaintext never touches argv or shell history):

```bash
printf '%s' 'something-long-and-random' | docker run --rm -i caddy:2.10-alpine caddy hash-password
```

### Deploy

```bash
docker compose up -d
docker compose logs -f caddy   # watch for successful cert issuance
```

Consider bringing it up against Let's Encrypt's staging CA first if you're
not confident DNS/port-forwarding is right yet — a failed production
attempt burns into real rate limits, a failed staging one doesn't. Drop
`acme_ca https://acme-staging-v02.api.letsencrypt.org/directory` into
`config/caddy/conf.d/global/01-acme-staging.caddy`, bring the stack up,
confirm a cert loads, then delete that file and restart caddy for the real
one. (This is exactly what the wizard automates.)

### <a id="truenas-custom-app-yaml"></a>TrueNAS Custom App (Install via YAML)

The Custom App installer doesn't read `.env`, and wants absolute host
paths rather than the `./config/...`-relative ones `docker-compose.yml`
uses — so there's a separate template, `truenas-custom-app.yaml.tmpl`,
with everything as `__TOKEN__` placeholders. The wizard renders it to
`truenas-custom-app.rendered.yaml` (gitignored — it contains your real
domains and hash) every time it runs, deploy or not. To render it without
deploying: `./scripts/setup.sh --skip-deploy`.

To do it by hand: copy the `.tmpl` file and replace every `__TOKEN__` with
a real value yourself (each one's meaning is in the file's own header
comment), then Apps → Discover Apps → *Custom App* → *Install via YAML*,
paste in the result.

Optional two-factor auth ([below](#optional-two-factor-authentication))
isn't included in this file — its `secrets:`/profile-gated-service pattern
is unreliable through the Custom App installer in practice, so add that
piece over SSH with the regular `docker-compose.yml` instead, once the
base stack is working.

### Create additional users and devices

The wizard creates your first user and a one-hour pre-auth key for your
first device. For anyone/anything after that:

```bash
./scripts/create-user.sh someone-else
./scripts/create-preauthkey.sh someone-else --expiration 1h
```

Single-use, short-lived keys are the default for a reason — avoid
`--reusable` unless you're doing scripted bulk enrollment (a leaked
reusable key admits unlimited devices as that user for as long as it's
valid; expire it immediately after with `headscale preauthkeys expire`).

```bash
tailscale up --login-server=https://headscale.yourdomain.com --authkey=<key>
```

Or, without a pre-auth key (interactive login):

```bash
tailscale up --login-server=https://headscale.yourdomain.com
```

This prints a URL — approve it with:

```bash
docker exec headscale headscale users list          # find the user
docker exec headscale headscale nodes register --user someone-else --key <nodekey-from-tailscale-up-output>
```

## Web admin UI (headscale-admin)

[headscale-admin](https://github.com/GoodiesHQ/headscale-admin) is a
browser-based UI for managing users, devices, and pre-auth keys, so you're
not stuck running `docker exec headscale headscale ...` for everything.
It's a static frontend — it holds no server-side state and talks to
headscale's REST API directly from your browser using an API key (the
wizard mints one and prints it at the end; `./scripts/create-apikey.sh`
for more later).

**Why this needs its own lock, beyond TLS:** headscale API keys are
unscoped — the same key that lets the UI list nodes can also create
users, mint pre-auth keys, and delete nodes. There's no read-only key.
And because `HEADSCALE_ADMIN_DOMAIN` gets a real Let's Encrypt certificate,
its hostname is published in public Certificate Transparency logs within
minutes — treat it as discoverable by internet scanners on day one, not
"security by an obscure name." So this domain is gated two ways before a
request ever reaches the app: an IP allowlist (`ADMIN_ALLOWED_CIDRS`, only
your tailnet + private LAN ranges by default) and HTTP basic auth on top
of that (the wizard generates both).

Visit `https://headscale-admin.yourdomain.com` from a device on your home
LAN or already on the tailnet (the IP allowlist blocks everyone else). If
your router doesn't do NAT hairpinning for your own public domain, browse
to the TrueNAS box's LAN IP directly instead while you're on that network.
You'll hit the basic-auth prompt first, then the app itself. Open
**Settings** and enter:
- **Headscale URL**: `https://headscale-admin.yourdomain.com` — i.e.
  the *admin* domain, not `HEADSCALE_DOMAIN`. Caddy proxies `/api/*` on
  the admin domain straight through to headscale, so the browser's calls
  stay same-origin and never hit the browser's CORS restrictions or
  headscale's own domain directly.
- **API Key**: from the wizard's summary, or `./scripts/create-apikey.sh`.

Treat the API key like a root credential to headscale, and the basic-auth
password the same way — anyone with both can manage every user and
device. Rotate the API key on its 30-day cycle; rotate the basic-auth
password if you ever suspect it leaked (`./scripts/setup.sh --reconfigure`,
or by hand: regenerate the hash, update `.env`, `docker compose up -d caddy`).

Note: `config.yaml`'s `policy.mode` is set to `file` (see
[Access control](#access-control)), so ACL editing from within
headscale-admin (if the version you're on offers it) won't take effect —
the huJSON file stays the source of truth, which is deliberate so policy
changes are reviewable/versioned rather than made silently from a browser.

## Access control

`config/headscale/acl.hujson` ships with a starter policy already wired up
via `policy.path` in `config.yaml` — by default it allows everything for a
`group:admins` containing your username (the wizard substitutes this; by
hand, replace the placeholder `"myself"`). Before relying on it further:

1. Edit `config/headscale/acl.hujson` — add more groups/rules as your
   tailnet grows past one user.
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

## Optional: two-factor authentication

Everything above (IP allowlist + basic auth) is the default and needs no
extra setup. If you want a second factor (TOTP, i.e. a 6-digit code from
an authenticator app) in front of headscale-admin as well, this stack can
run [Authelia](https://www.authelia.com) as an opt-in `docker compose`
[profile](https://docs.docker.com/compose/how-tos/profiles/) — it stays
off, and nothing above changes, unless you do all of the following. (This
one is still a manual, from-scratch setup — the wizard doesn't fold it in
yet.)

1. **A third subdomain.** Add one more DNS record the same way as
   [above](#dns-and-port-forwarding) — a `CNAME` named e.g. `auth`
   pointing at your step-2 record — for `AUTHELIA_DOMAIN` (Authelia's own
   login portal lives here; it's a separate origin from
   `HEADSCALE_ADMIN_DOMAIN` by design, matching Caddy's `forward_auth`
   model).
2. **Generate secrets:**
   ```bash
   ./scripts/setup-2fa-secrets.sh
   ```
   Writes three random keys into `./secrets/` (gitignored). Losing or
   regenerating `authelia_storage_encryption_key` later makes Authelia's
   database unreadable — back up `./secrets/` and `./data/authelia`
   together (not covered by `scripts/backup.sh`, which is headscale-only).
3. **Create your admin account:**
   ```bash
   cp config/authelia/users_database.yml.example config/authelia/users_database.yml
   docker run --rm -it authelia/authelia:4.39.20 authelia crypto hash generate argon2
   ```
   Paste the resulting hash into `config/authelia/users_database.yml`
   (replacing the placeholder), and set a real email address there —
   Authelia wants one even though this setup doesn't send mail (see
   below).
4. **Edit `config/authelia/configuration.yml`** — replace the four
   `CHANGE-ME` placeholders with your real `AUTHELIA_DOMAIN`,
   `HEADSCALE_ADMIN_DOMAIN`, and zone apex (e.g. `yourdomain.com`, which
   must cover both subdomains as Authelia's session cookie is set at that
   level).
5. **Set in `.env`:**
   ```
   AUTHELIA_DOMAIN=auth.yourdomain.com
   ADMIN_AUTH_SNIPPET=forward_auth_gate
   ```
6. **Enable the Authelia site block:**
   ```bash
   cp config/caddy/conf.d/sites/10-authelia.caddy.example config/caddy/conf.d/sites/10-authelia.caddy
   ```
   (Caddy imports everything under `conf.d/sites/*.caddy` automatically —
   nothing else to edit.)
7. **Start it:**
   ```bash
   docker compose --profile 2fa up -d
   ```
   From now on, include `--profile 2fa` on every `docker compose` command
   that should include Authelia (`up`, `pull`, `logs`, etc.) — plain
   `docker compose up -d` without the flag leaves it stopped.
8. Visit `https://headscale-admin.yourdomain.com`, get redirected to the
   Authelia portal, log in with the account from step 3, and enroll TOTP
   by scanning the QR code it shows on first login (any authenticator
   app — Aegis, Ente Auth, 1Password, etc. all work).

No SMTP is configured — Authelia writes password-reset/identity-verification
links to a file instead of emailing them, since this is meant for one
admin account, not a multi-user portal:
```bash
docker exec authelia cat /data/notification.txt
```
Password reset is disabled outright in `configuration.yml`
(`authentication_backend.password_reset.disable: true`) — regenerate the
hash from step 3 and edit `users_database.yml` directly if you forget it.

To go back to basic-auth-only: set `ADMIN_AUTH_SNIPPET=basic_auth_gate`
(or delete the line) in `.env`, `docker compose up -d caddy`, and
optionally `docker compose --profile 2fa stop authelia`.

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

**headscale / caddy / headscale-admin / authelia** are all pinned by tag
*and* digest in `docker-compose.yml` — `docker compose pull` alone won't
change what's running, on purpose (`headscale-admin` in particular runs
same-origin with the API and holds a bearer key in the browser, and
`authelia` holds your login credentials and TOTP state, so silently
picking up unreviewed upstream changes is a real risk here, not just a
stability nicety). To upgrade a service deliberately:

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

Start with `./scripts/doctor.sh` — it re-runs the wizard's own checks
(host, config, DNS, runtime) any time, without changing anything, and
`./scripts/doctor.sh --logs` translates common Caddy/headscale log
signatures into plain English instead of leaving you to grep. The entries
below are the ones that need human judgment rather than a mechanical check.

- **`tailscale up` connects but nothing routes**: check
  `docker exec headscale headscale nodes list` — the node needs to show as
  registered and online.
- **Changed `dns.base_domain` after devices already joined**: existing
  devices need `tailscale up` re-run to pick up the new MagicDNS suffix.
- **headscale-admin shows a network/CORS error**: double check you entered
  the *admin* domain (not `HEADSCALE_DOMAIN`) as the Headscale URL in its
  Settings page — that's what makes its API calls same-origin through
  Caddy's `/api/*` route instead of cross-origin.
- **Can't reach the admin UI at all, even with the right URL**: you're
  outside `ADMIN_ALLOWED_CIDRS`. If you're on your home LAN and still
  blocked, your router likely doesn't NAT-hairpin your own public domain
  back to itself — browse to the TrueNAS box's LAN IP instead while
  you're on that network, or add your LAN's actual observed source range
  to `ADMIN_ALLOWED_CIDRS` in `.env`.
- **A container won't start after an update**: `headscale` and `caddy`
  run with a read-only root filesystem and a dropped capability set. If
  `headscale-admin` specifically fails, check
  `docker compose logs headscale-admin` — its startup process may need a
  capability not in the `cap_add` list in `docker-compose.yml`; loosen
  that service's `cap_drop`/`cap_add` (or remove them) rather than the
  other two.
- **Locked out of headscale-admin after enabling 2FA**: TOTP codes are
  time-based — check the TrueNAS box's clock (`date`, or
  `./scripts/doctor.sh`) and your phone's clock are both accurate. As a
  last resort, set `ADMIN_AUTH_SNIPPET=basic_auth_gate` in `.env` and
  `docker compose up -d caddy` to fall back to basic auth without needing
  Authelia to cooperate.
- **Plain `docker compose up -d` (no `--profile 2fa`, no interest in 2FA)
  errors about a missing file under `./secrets/`**: the `authelia`
  service is profile-gated and shouldn't need its secrets to exist just
  to leave it stopped, but if your Compose version is stricter about
  this, running `./scripts/setup-2fa-secrets.sh` once is harmless even if
  you never enable the profile — it only writes three small text files.

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
- **The setup wizard doesn't fold in 2FA, Cloudflare DNS API automation,
  or CI parity-checking between `docker-compose.yml` and the TrueNAS
  template.** All three are reasonable follow-ups; none are silently
  half-implemented — 2FA is a complete manual walkthrough
  ([above](#optional-two-factor-authentication)), and the other two are
  simply not built.
