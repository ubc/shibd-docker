# Docker Image for Clustered Shibd

The Shibboleth SP 3 daemon (`shibd`) on Rocky Linux 9. It pairs with a web
server running `mod_shib`, which connects to it over TCP port 1600. At every
start `docker-entrypoint.sh` renders `/etc/shibboleth/shibboleth2.xml` and
`console.logger` from the environment (`render-config.sh`), then runs
`shibd -F -u shibd`.

## Session storage

`SHIBD_STORAGE` picks where sessions, the replay cache and the artifact map
live:

- `odbc` (default): a shared MariaDB/MySQL database through ODBC, so any number
  of replicas share sessions. The entrypoint waits for the database and creates
  the `version`, `strings` and `texts` tables it needs.
- `memory`: inside the shibd process. No database, no ODBC library, no wait.
  The catch:
  - Run exactly **one** replica. Each shibd only knows its own sessions.
  - Sessions are lost when the container restarts: everyone signs in again,
    and a login in progress at that moment ends on `SHIBBOLETH_HOME_URL`
    (below).
  - A second replica needs sticky sessions at the load balancer (and still
    loses that replica's sessions when it goes away) or `odbc`.
  - Every login an anonymous visitor starts keeps its target URL (relay
    state, `ss:mem`: about 4 KB, more for a long URL) in shibd's memory for
    10 minutes. A flood of unauthenticated requests to protected URLs grows
    shibd until its memory limit kills it, and that logs everyone out. Give
    the container headroom (CWL Pages uses 512Mi), rate-limit at the ingress,
    and keep request lines short in the web server.
  - A login whose relay state is gone (more than 10 minutes at the IdP, or a
    restart or another replica in between) still signs the user in, but lands
    on `SHIBBOLETH_HOME_URL` instead of the page they asked for.

Any other value stops the container with an error.

Memory mode also renders a few things differently from `odbc` (which keeps
its configuration byte for byte). The web container's `mod_shib` must render
`<Sessions>` (with its handlers and `<Logout>`), `homeURL` and the
`<SessionCache>` attributes the same way:

- `<Sessions redirectLimit="exact">`: Login, Logout and the ACS only redirect
  back to the SP's own host, so `/Shibboleth.sso/Logout?return=https://elsewhere`
  is refused instead of being an open redirect.
- `<ApplicationDefaults homeURL="${SHIBBOLETH_HOME_URL}">` (default `/`, which
  is what the SP does without one): where a login lands when its relay state
  is gone, see above. Point it at a public page that says "you're signed in,
  open your link again" rather than at a page the user may not be allowed to
  see.
- `<Logout>Local</Logout>`: `/Shibboleth.sso/Logout` ends the session here
  only, with no SAML 2 single logout at the IdP. shibd sets up no
  SingleLogoutService endpoints, so `/Shibboleth.sso/Metadata` lists none and
  there is nothing to register with the IdP for logout. `odbc` keeps
  `SAML2 Local`.
- The Local logout initiator is at `/Logout/Redirect`. The template's
  `"/Logout/Redirect "` (trailing space) can't be reached by any URL from a
  `mod_shib` in another container, which addresses handlers by Location.
- `<SessionCache ... cacheAllowance="3600">` without the deprecated
  `cacheTimeout`, so `SHIBBOLETH_CACHE_TIMEOUT` is not used: a session stays
  in storage for the idle timeout (`SHIBBOLETH_SESSION_TIMEOUT`) plus
  `cacheAllowance` after its last use, and shibd logs no deprecation warning.
- Login events (the transaction log) go to the console like every other log
  line, and leave out the user, NameID, session ID (the cookie value), user
  agent and client address: `tranLogFormat="%IDP|%i|%ac|%t|%attr|%b|%E|%S|%SS|%L"`
  (`%attr` lists attribute ids and counts, never values). Otherwise the stock
  `shibd.logger`, read before `console.logger`, keeps them in
  `/var/log/shibboleth/transaction.log` inside the container.
- The `Shibboleth.SessionCache` log category is at `WARN`. At `INFO` it logs
  every session ID, which is the session cookie's value and replays the
  session, with the client address ("new session created", "removed
  session"). With this and the trimmed login events above, the log has no
  CWLs, session IDs or client addresses at `INFO`. A few rare `WARN` lines (a session missing at logout or
  after recovery) still name a session ID.
- shibd runs under `stdbuf -oL`. Its console appender writes through C
  stdio, which is block-buffered when stdout is a pipe, so log lines reached
  `docker logs`/`kubectl logs` only 4 KB at a time or at exit.

## Environment variables

Settings marked *required* have no default; leaving them empty renders a
configuration shibd rejects or that cannot work.

### Identity and metadata

| Variable | Default | Meaning |
|---|---|---|
| `SHIBBOLETH_SP_ENTITY_ID` | *required* | The SP's entityID, e.g. `https://app.example.ubc.ca/shibboleth`. Also used for the generated key pair, see `SHIB_SP_CERT`. |
| `SHIBBOLETH_IDP_ENTITY_ID` | *required* | The IdP that `<SSO>` sends users to, e.g. `https://authentication.stg.id.ubc.ca` (staging) or `https://authentication.ubc.ca` (production). With `SHIBBOLETH_IDP_METADATA_FILE`, also the only IdP kept from that file (see below); no spaces, quotes, `<`, `>` or `&`. |
| `SHIBBOLETH_IDP_DISCOVERY_URL` | *required* | Discovery service URL. Unused while `<SSO>` names an IdP, but it must be non-empty; the IdP base URL is fine. |
| `SHIBBOLETH_IDP_METADATA_FILE` | empty | Path to a local IdP metadata file, e.g. a mounted Secret or ConfigMap at `/etc/shibboleth/idp/idp-metadata.xml`. When set, shibd reads only that file and fetches nothing, and the two variables below are ignored. Letters, digits, `.`, `_`, `-` and `/` only. The container stops at start if shibd couldn't use the file, see [IdP metadata from a file](#idp-metadata-from-a-file). |
| `SHIBBOLETH_IDP_METADATA_URL` | *required* unless `SHIBBOLETH_IDP_METADATA_FILE` is set | Where to download IdP metadata, reloaded daily, e.g. `https://authentication.stg.id.ubc.ca/idp/shibboleth`. |
| `SHIBBOLETH_IDP_METADATA_BACKUPFILE` | `/var/cache/shibboleth/shibboleth-metadata-idp.xml` | Local copy of the downloaded metadata, used when the download fails. |
| `SHIBD_ATTRIBUTE_MAP_URL` | empty | Download the attribute map from this URL instead of using `/etc/shibboleth/attribute-map.xml` from the image. |
| `SHIBD_REMOTE_USER` | `somerandomname` | Attribute id(s), space separated, that become `REMOTE_USER`, e.g. `uid` or `eppn`. |

### Listener

| Variable | Default | Meaning |
|---|---|---|
| `SHIBD_LISTENER_ADDRESS` | *required* | Address shibd listens on (port 1600): `127.0.0.1` when `mod_shib` is in the same pod, `0.0.0.0` otherwise. |
| `SHIBD_LISTENER_ACL` | *required* | Space-separated addresses or CIDRs allowed to connect, e.g. `127.0.0.1`. |

### Sessions and handlers

| Variable | Default | Meaning |
|---|---|---|
| `SHIBBOLETH_SESSION_LIFETIME` | `7200` | Maximum session length in seconds. |
| `SHIBBOLETH_SESSION_TIMEOUT` | `3600` | Idle timeout in seconds. |
| `SHIBBOLETH_CACHE_TIMEOUT` | `3600` | `odbc` only: SessionCache `cacheTimeout` in seconds. shibd logs a deprecation warning for it; harmless. Memory mode renders no `cacheTimeout` and ignores this. |
| `SHIBBOLETH_COOKIE_PROPS` | `http` | `http`, `https` (adds `secure`), or literal cookie properties. Use `https` behind TLS. |
| `SHIBBOLETH_HANDLER_SSL` | `false` | `true` makes the `/Shibboleth.sso` handlers refuse plain HTTP. The web server must then see requests as HTTPS (behind a TLS-terminating proxy, e.g. Apache `ServerName https://host:443` with `UseCanonicalName On`). Any value other than `true`/`false` stops the container. |
| `SHIBD_CONSISTENT_ADDRESS` | `true` | Shibboleth's `consistentAddress` session setting. |
| `SHIBBOLETH_HOME_URL` | `/` | Memory mode only: `<ApplicationDefaults homeURL>`, where a login whose relay state is gone lands. A path starting with `/` or an `https://` URL, from letters, digits and `. _ ~ / % : ? = + -`; anything else stops the container. Set it to the same value in the web container. |

### Storage

| Variable | Default | Meaning |
|---|---|---|
| `SHIBD_STORAGE` | `odbc` | `odbc` or `memory`, see above. |
| `SHIBD_ODBC_LIB` | *required for odbc* | Extension library, normally `odbc-store.so`. |
| `SHIBD_ODBC_DRIVER` | *required for odbc* | ODBC driver name, e.g. `MySql`. |
| `SHIBD_ODBC_SERVER` | *required for odbc* | Database host. |
| `SHIBD_ODBC_PORT` | *required for odbc* | Database port, e.g. `3306`. |
| `SHIBD_ODBC_DATABASE` | *required for odbc* | Database name. |
| `SHIB_ODBC_USER` | *required for odbc* | Database user. |
| `SHIB_ODBC_PASSWORD` | *required for odbc* | Database password. |

### Keys, logging and build

| Variable | Default | Meaning |
|---|---|---|
| `SHIB_SP_CERT`, `SHIB_SP_KEY` | empty | PEM text of the SP certificate and key, written to `/etc/shibboleth/cert/` when `sp-key.pem` is not already there (for example from a mounted Secret). With neither and no mounted key, the entrypoint generates a 10-year self-signed pair, so the SP's key changes on every restart unless that directory persists. |
| `LOG_LEVEL` | `INFO` | Root log level. Keep it at `INFO` or above in production: `DEBUG` logs whole SAML assertions, names and email addresses included. |
| `SHIBD_VERSION` | `3.5.0-1.el9` | Shibboleth RPM installed at build time; changing it at run time does nothing. |
| `SSH_ENABLED`, `SSH_PUBLIC_KEY` | unset | `Dockerfile-debug` only (the main image has no sshd): start sshd and allow this key for root. |

## IdP metadata from a file

With `SHIBBOLETH_IDP_METADATA_FILE` set:

- Only `SHIBBOLETH_IDP_ENTITY_ID` is kept from the file
  (`<MetadataFilter type="Include">`). Any other IdP in it, say from an
  aggregate or two files pasted together, is dropped with the INFO line
  `filtering out non-included entity (...)` and can't log anyone in.
- Before starting shibd, the entrypoint runs `check-idp-metadata.sh`, which
  stops the container with one `ERROR:` line naming the file and the expected
  entityID (and nothing from the file) when the file is missing, can't be read
  by the user and group shibd runs as (its `-u` and `-g`; shibd reads the file
  after dropping root), is not well-formed XML (checked with `xmllint`), or
  has no `EntityDescriptor` in the SAML metadata namespace, under any prefix,
  whose `entityID` is exactly `SHIBBOLETH_IDP_ENTITY_ID`. shibd itself would
  start anyway with no IdP, log `CRIT ... Include MetadataFilter instructed to
  filter the root/only entity` or `CRIT ... Unable to access local file`, and
  fail every login.
- shibd re-reads the file when it changes, without a restart (the provider's
  default `reloadChanges`). An updated Kubernetes Secret or ConfigMap reaches
  the running shibd on the kubelet's next sync, so store new IdP metadata only
  when it should take effect, or use a file that carries both the old and the
  new signing key during a key rollover.
- That check runs only at start. A file changed under a running shibd (say,
  new metadata written to Vault reaching the Secret) is re-read without it,
  so metadata without the IdP, or broken, is not caught and can make logins
  fail while the container keeps running. After changing the metadata, once
  the new file is in the container, run the same check there with the
  container's command, e.g. `docker exec <container> /check-idp-metadata.sh
  shibd -F -u shibd` or `kubectl exec <pod> -c shibd -- /check-idp-metadata.sh
  shibd -F -u shibd -g shibd`. It prints nothing and exits 0 when the file is
  fine. A restart runs it too, but with a bad file shibd then doesn't start
  at all.
- The metadata is checked against the SAML schema only. The file is unsigned
  and has no expiry, so check where it came from (and the IdP certificate's
  fingerprint) before storing it.

To see what shibd will use for an IdP:
`docker exec <container> mdquery -e <entityID> -saml2 -idp` prints the IdP's
`<IDPSSODescriptor>`, or logs `compatible role ... not found` when there is
none (for example, because it was filtered out).

## Files and permissions

- `/etc/shibboleth/cert/sp-cert.pem` and `sp-key.pem`: the SP key pair. The
  container starts as root, renders the configuration, then shibd drops to the
  `shibd` user (uid 998, primary group 0 because only `-u` is passed,
  supplementary group 998; run `shibd -F -u shibd -g shibd` for primary group
  998). shibd reads the key when it first needs it, after dropping root, so the
  key must be readable by uid or gid 998. In Kubernetes, for example, mount the
  Secret with `defaultMode: 0440` and give the pod `fsGroup: 998`. Check the
  ids of a build with `docker run --rm --entrypoint id <image> shibd`.
- The entrypoint gives a writable `/etc/shibboleth/cert` to `shibd:shibd`, and
  leaves a read-only one (a Secret, a `:ro` volume) alone without a message.
- The image has no SP key of its own. The shibboleth RPM generates
  `sp-signing-*.pem` and `sp-encrypt-*.pem` in `/etc/shibboleth` when it is
  installed; the build deletes them in the same layer (nothing uses them, and
  a key in a public image is not secret). Without a mounted key pair or
  `SHIB_SP_CERT`/`SHIB_SP_KEY`, the entrypoint generates one at start.
- `/etc/shibboleth/attribute-map.xml`: baked into the image; mount a file over
  it to change the mapping.
- `/etc/shibboleth` must be writable at start (the entrypoint writes the
  rendered files there), so a read-only root filesystem needs an emptyDir or
  similar over it.

## Image tags

CI (`.github/workflows/main.yml`) pushes `lthub/shibd:<branch>` on every push
to a branch whose name has no `/`, plus `:sha-<short commit>` and release
tags. Branch tags move, and `rocky9` is shared with moodle. A deployment that
must not change under it pins a digest, e.g. `lthub/shibd@sha256:...`
(`docker buildx imagetools inspect lthub/shibd:sha-<short>` prints it), with
`imagePullPolicy: IfNotPresent`, and moves to a new digest only after testing
it with its web container.

## Example: one replica with in-memory sessions

```sh
docker run -d --name shibd \
  -e SHIBD_STORAGE=memory \
  -e SHIBBOLETH_SP_ENTITY_ID=https://app.example.ubc.ca/shibboleth \
  -e SHIBBOLETH_IDP_ENTITY_ID=https://authentication.stg.id.ubc.ca \
  -e SHIBBOLETH_IDP_DISCOVERY_URL=https://authentication.stg.id.ubc.ca \
  -e SHIBBOLETH_IDP_METADATA_FILE=/etc/shibboleth/idp/idp-metadata.xml \
  -e SHIBBOLETH_HANDLER_SSL=true -e SHIBBOLETH_COOKIE_PROPS=https \
  -e SHIBD_REMOTE_USER=uid \
  -e SHIBD_LISTENER_ADDRESS=127.0.0.1 -e SHIBD_LISTENER_ACL=127.0.0.1 \
  -e SHIBBOLETH_HOME_URL=/signed-in \
  -v "$PWD/idp-metadata.xml:/etc/shibboleth/idp/idp-metadata.xml:ro" \
  -v "$PWD/cert:/etc/shibboleth/cert:ro" \
  lthub/shibd:rocky9
```

## Tests

```sh
tests/run.sh                                   # build lthub/shibd:memory-test for this machine and test it
PLATFORM=linux/amd64 IMAGE=lthub/shibd:amd64-test tests/run.sh   # what CI builds
```

The script needs docker, git and shellcheck. `.github/workflows/test.yml`
runs it on every push and pull request; it does not gate the publish workflow,
so look at its result before merging. It checks that:

- ODBC configurations render byte-identical to the original entrypoint and
  templates (`BASELINE_REF`, by default the rocky9 commit before memory
  storage), and that every case in `tests/fixtures/render/` matches
  `tests/fixtures/expected/`. After an intended template change, regenerate
  those with `UPDATE_GOLDEN=1 tests/run.sh` and review the diff.
- Bad `SHIBD_STORAGE`, `SHIBBOLETH_HANDLER_SSL`, `SHIBBOLETH_HOME_URL` or
  `SHIBBOLETH_IDP_METADATA_FILE` values, or a metadata file without
  `SHIBBOLETH_IDP_ENTITY_ID`, stop the container.
- A metadata file that is missing, malformed, unreadable for shibd's `-u` and
  `-g` user and group, or without an `EntityDescriptor` for exactly
  `SHIBBOLETH_IDP_ENTITY_ID` (another IdP, a prefix of it, no namespace)
  stops the container with one line before it generates a key pair. `md:`
  prefixed metadata passes (and `shibd -t` loads it), also with only the
  SETUID and SETGID capabilities, and the check runs by hand with
  `docker exec`.
- The image has none of the RPM's generated key pairs, in its file system or
  in any layer (`SKIP_LAYER_SCAN=1` skips the layer scan).
- Memory mode passes `shibd -t`, keeps running with no network, listens only on
  127.0.0.1:1600, logs nothing about ODBC or a database, renders the
  memory-only settings above, and has its last start-up line in the logs
  while it runs (line-buffered). Its log has no `INFO` line from the session
  cache, no `cacheTimeout` deprecation warning, a Local-only `/Logout` chain
  with no SingleLogoutService, and no `chown` complaint about the read-only
  cert mount; a writable cert directory still goes to `shibd`.
- With a second IdP in the metadata file, shibd starts and `mdquery` finds
  only the configured one.
- ODBC mode still starts against MariaDB and creates its tables
  (`SKIP_ODBC_E2E=1` skips this).

A real login (redirect limits, `homeURL`, logout, what the login events and
the session cache log) is covered by the CWL Pages E2E suite
(`cwl-pages-web/tests/e2e`), which has an IdP.

`render-config.sh` explains the `##IF_<FLAG>##` and `##STORAGE_ID##` markers
in `shibboleth2.xml-template` and `console.logger-template`.
