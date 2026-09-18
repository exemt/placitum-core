# Controller API

English · [Русский](API.ru.md)

Everything in Placitum is configured through one HTTP API: the panel, the installer and your own
scripts all talk to the controller. The panel has no private back door, so anything you can click
you can also do from a script.

This page is the reference: where the API listens, how a request looks, what happens after a write,
and what every endpoint does. Installation itself is in [INSTALL.md](INSTALL.md).

## Where it listens

By default the controller is at `http://127.0.0.1:8080` — the machine itself only. The port comes
from `PLC_CONTROLLER_PORT` in `.env`.

From another machine, open a tunnel:

```sh
ssh -L 8080:127.0.0.1:8080 user@server
```

## Access

The API has no login of its own. Whoever reaches the port acts as the operator of the installation:
there are no roles, no tokens and no read-only mode. Two things keep that safe, and both are set up
by the installer:

- the port is bound to loopback (in Docker by the compose file, without Docker by `CONTROLLER_HOST`);
- the panel is served by the node behind the `auth` login gate, and the browser reaches the API
  through that same gate.

Do not publish port 8080. A session on that port is as good as root on the node.

The API also guards itself against other people's web pages. A request that changes something
(anything but `GET`, `HEAD` and `OPTIONS`) must come from the same origin or from an origin listed
in `CONTROLLER_CORS_ORIGIN`, otherwise the answer is `403 cross_origin`. A request without `Origin`
and without `Sec-Fetch-Site` — curl, the installer, a script — is a tool, not a page, and passes.

## How a request looks

- JSON in, JSON out. Send `Content-Type: application/json` with a body.
- There is no version in the path. The API is the one of the version you installed; `GET /api/meta`
  tells you which that is.
- Field names are `snake_case`, identifiers are called `uuid`, time is ISO 8601 in UTC.
- A JSON body is accepted up to about 3 MB (`CONTROLLER_STORE_MAX_BYTES` × 1.4, 2 MiB by default).
  Uploads that are not JSON — a geo database, a page, a certificate — have their own limits.
- `PUT` is a patch: a field you leave out keeps its value. A field you do send is taken whole — a
  profile `doc` or an `nginx` block replaces the old one, it is not merged into it.
- The same address also serves the panel. A path that is neither `/api/…` nor `/healthz` returns the
  panel page, not a 404.

## Scope

Almost every path starts with the uuid of an HTTP space:

```
/api/<scope>/servers
```

A space is a whole nginx configuration: its servers, locations, lists, profiles and inspectors. A
fresh installation has one, named `default`. Find its uuid first:

```sh
curl -s http://127.0.0.1:8080/api/spaces
```

```json
{
  "spaces": [
    {
      "uuid": "00000000-0000-4000-8000-000000000001",
      "name": "default",
      "raw": false,
      "created_at": "2026-09-12T15:27:32.862Z",
      "updated_at": "2026-09-17T12:34:39.625Z"
    }
  ]
}
```

The examples below assume it is in a variable:

```sh
SCOPE=$(curl -s http://127.0.0.1:8080/api/spaces | jq -r '.spaces[0].uuid')
API=http://127.0.0.1:8080/api/$SCOPE
```

A uuid that is not a uuid gives `400 invalid_scope`; a uuid of a space that does not exist gives
`404 unknown_scope`.

## Errors

An error is always JSON with the same envelope:

```json
{ "error": "not_found" }
```

Some errors add fields that say what exactly went wrong: `detail`, `names`, `uses`, `invalid`,
`known`, `max`, `errors`.

| Status | When |
| --- | --- |
| `400` | the request is wrong: a bad uuid, a missing field, a value the field does not take |
| `403` | `cross_origin`: a write came from a foreign page |
| `404` | no such object, or no such space |
| `409` | the object is in use, or the name is taken |
| `413` | the body is larger than the limit |
| `422` | the request is valid but the configuration it makes is not — see `errors` |
| `500` | `internal_error`: an unhandled failure, look in the controller log |
| `503` | a neighbour is unavailable: the key-value store, the search service, the crypto service |

Codes you meet everywhere:

| Code | Meaning |
| --- | --- |
| `invalid_scope`, `unknown_scope` | the space uuid in the path |
| `invalid_uuid`, `not_found` | the object uuid in the path |
| `name_taken`, `address_taken`, `path_taken`, `port_taken` | a unique name or address is already used |
| `in_use` | something else references this object; delete the reference first |
| `default_required`, `default_name_locked` | the `default` profile cannot be deleted or renamed |
| `builtin_locked`, `builtin_name_locked` | a shipped object cannot be changed or renamed |
| `validation_failed` | the configuration did not compile; `errors` lists the reasons |
| `kv_unavailable` | the bus is down, so nothing could be published |

## Saving and publishing

A write changes the controller's database and nothing else. The node and the inspectors keep running
on what they already have. Publishing is a separate, explicit step:

1. **Save** — `POST`, `PUT` or `DELETE` on the objects of a channel.
2. **Send** — `POST .../send` on that channel. The controller compiles what it has, writes the new
   generation to the bus and answers with its revision and hash.
3. **Apply** — the processes read the generation, apply it and report what they run.
4. **Check** — `GET /api/<scope>/convergence` compares what is saved, what is published and what
   each process reports.

Channels are independent: rules for the `modsec` inspector travel on their own, the node
configuration on its own.

| Channel | What it carries | Send | Published generation |
| --- | --- | --- | --- |
| `nginx` | servers, locations, ports, certificates, space settings | `POST config/send` | `GET config/desired` |
| `agent` | node agent settings | `POST agent/send` | `GET agent/desired` |
| `haproxy` | balancer settings | `POST haproxy/send` | `GET haproxy/desired` |
| `rules` | ModSecurity rule files and sets | `POST rules/send` | `GET rules/desired` |
| `ip` | IP profiles and sets | `POST ip-profiles/send` | `GET ip-profiles/desired` |
| `auth`, `captcha`, `json`, `action`, `cookie`, `counter`, `vlai`, `rewrite` | profiles of that inspector | `POST <name>/send` | `GET <name>/desired` |

A send answers with the generation it wrote:

```json
{ "v": 1, "rev": 68, "config_hash": "sha256:75c22e…", "store": 0, "pages": ["blocked.html"] }
```

`rev` grows by one per generation. If nothing changed, the revision stays and the send is a no-op.

The convergence snapshot has one lamp for the whole space (`green`, `yellow`, `red`) and one entry
per channel: the draft hash, the published hash and revision, and every consumer with what it
reports (`ok`, `stale`, `pending`, `failed`, `foreign`, `silent`).

## Service

| Endpoint | What it gives |
| --- | --- |
| `GET /healthz` | `ok` as plain text, without touching the database |
| `GET /api/health` | `{"ok":true,"db":true}` after a database ping |
| `GET /api/meta` | service name, version, host, pid, uptime |

## Spaces, fleet and convergence

| Endpoint | What it does |
| --- | --- |
| `GET /api/spaces` | all HTTP spaces: uuid, name, timestamps |
| `GET /api/fleet` | one snapshot of everything running: node agents and their workers, inspectors, object stores, services, traffic per route |
| `POST /api/fleet/forget` | forget processes by name after their containers are gone |
| `GET /api/<scope>/convergence` | what is saved, what is published, what each process reports |
| `POST /api/<scope>/convergence/refresh` | recount it; `?channel=nginx` for one channel |

A fleet member is `up` or `degraded` and disappears when it stops reporting. Each row carries its
last heartbeat, the hash and revision it runs, the result of the last apply, and its counters.

`POST /api/fleet/forget` takes the names the installer removed and answers with what it dropped:

```sh
curl -s -X POST http://127.0.0.1:8080/api/fleet/forget \
  -H 'content-type: application/json' \
  -d '{"names":["edge-02"]}'
```

```json
{ "forgotten": 3, "agents": ["9a1c…"], "inspectors": 2, "stores": 0, "services": 0 }
```

Names are node ids and container hostnames, up to 512 per call; a bad list is `400 invalid_names`.
A process that is still alive reappears with its next heartbeat.

### Live feed

The same snapshot is pushed over a WebSocket:

```
ws://127.0.0.1:8080/agent_health_socket
```

The first message is the full snapshot, then one per change, at most one per second. The feed is
one-way: whatever the client sends is ignored. A browser page can only open it from an allowed
origin — the same rule as for writes. A ping every 30 seconds drops sockets that stopped answering.

## Reference data

Read-only lists the panel builds its forms from. Useful for a script that has to name things the way
the installation names them.

| Endpoint | What it gives |
| --- | --- |
| `GET /api/actions` | the action vocabulary: axes, verbs, their parameters and which inspectors listen |
| `GET /api/<scope>/catalog` | one bundle: deny responses, log formats, lists, inspectors, subjects, profiles, pages, body stores, upstreams |
| `GET /api/<scope>/content-types` | content types for `content` lists |
| `GET /api/<scope>/crypto` | the contour public key, its algorithm and fingerprint |
| `GET /api/log-levels` | current log levels and the services that take them |
| `PUT /api/log-levels` | set them: `{"levels":{"controller":"debug"}}` |

Log levels apply across the installation at once, without a send: the document goes to the bus and
every process picks its own line out of it. A name that is not in `services` is refused with
`400 unknown_service`; `null` or an empty string drops the override and the process falls back to
its own setting.

## Servers, locations, ports, upstreams

These four make the node configuration. They all live in the `nginx` channel, so a change is only on
the node after `POST config/send`.

| Endpoint | What it does |
| --- | --- |
| `GET /api/<scope>/servers` | servers with their listens and location counts |
| `POST /api/<scope>/servers` | create a server |
| `GET`, `PUT`, `DELETE /api/<scope>/servers/<uuid>` | read, change, delete one |
| `GET /api/<scope>/servers/<uuid>/inheritance` | what this server inherits from the space, field by field |
| `GET /api/<scope>/servers/<uuid>/locations` | its locations in order |
| `POST /api/<scope>/servers/<uuid>/locations` | add a location |
| `PUT /api/<scope>/servers/<uuid>/locations/order` | reorder them: `{"order":["uuid","uuid",…]}` — every location of the server, once each |
| `GET`, `POST /api/<scope>/servers/<uuid>/ports` | which ports the server listens on; bind one more with `{"port_id":"…","default_server":false}` |
| `PUT`, `DELETE /api/<scope>/servers/<uuid>/ports/<bind>` | change or drop a binding |
| `GET`, `POST /api/<scope>/servers/<uuid>/certificates` | certificates bound to the server |
| `DELETE /api/<scope>/servers/<uuid>/certificates/<bind>` | unbind one |
| `GET`, `POST /api/<scope>/ports` | the ports of the space |
| `GET`, `PUT`, `DELETE /api/<scope>/ports/<uuid>` | one port: address, number, `ssl`, `http2`, `proxy_protocol` |
| `GET /api/<scope>/locations` | all locations of the space; `?server=<uuid>` narrows it to one server |
| `GET`, `PUT`, `DELETE /api/<scope>/locations/<uuid>` | one location |
| `GET /api/<scope>/locations/<uuid>/inheritance` | what it inherits from the space and the server |
| `GET`, `POST /api/<scope>/upstreams` | upstreams with their peers |
| `GET`, `PUT`, `DELETE /api/<scope>/upstreams/<uuid>` | one upstream |

A server carries `nginx` and `waf` documents: the first is nginx behaviour (real ip, proxy headers,
timeouts), the second is protection — which inspectors run there and with which profiles. A location
carries the same two, plus its handler: `proxy` to an upstream, or a return.

`raw: true` on a space, server or location means its text is written by hand in `raw_nginx` and the
controller only checks that the configuration compiles.

A port that a server still listens on cannot be deleted: `409 port_bound`. An upstream a location
still points at gives `409 upstream_bound`.

## Space settings

| Endpoint | What it does |
| --- | --- |
| `GET /api/<scope>/http` | the space: `nginx_main`, `nginx`, `waf_http`, `waf`, and the infrastructure addresses |
| `PUT /api/<scope>/http` | change them |
| `GET /api/<scope>/http/inheritance` | the space layer as servers and locations see it |

`infra` shows where the node's neighbours are — the bus and both Redis instances. It is read-only:
a `PUT` ignores it, and the Redis URLs come back with their passwords replaced by `***`.

## Certificates and the object store

A certificate is never sent as a field. The file goes into the object store first, encrypted with the
contour key, and the certificate then refers to the stored objects.

| Endpoint | What it does |
| --- | --- |
| `POST /api/<scope>/store` | put an object: `{"type":"…","metadata":{…},"blob":"<base64>"}`, answers `201` with its uuid |
| `GET /api/<scope>/store` | the catalogue: uuid, type, metadata, size — without blobs |
| `GET /api/<scope>/store/<uuid>` | metadata and the blob in base64 |
| `GET /api/<scope>/store/<uuid>/meta` | metadata only |
| `GET /api/<scope>/store/<uuid>/blob` | the raw ciphertext, for the agent |
| `GET`, `POST /api/<scope>/certificates` | certificates of the space; create one from stored objects |
| `GET`, `DELETE /api/<scope>/certificates/<uuid>` | one certificate |
| `PUT`, `DELETE /api/<scope>/certificates/<uuid>/crl` | attach or drop a revocation list |

An object's `type` is one of `certificate`, `private_key`, `chain`, `ca`, `crl`, `creds`,
`dhparam`, `deny_page`, `other`. An object is written once and read many times: it has neither a
`PUT` nor a `DELETE`.

Creating a certificate takes `{"name":"…","type":"server","cert_store_id":"…","key_store_id":"…"}`;
`type` is `server` or `client_ca`, and a server certificate needs a key. The controller asks the
crypto service for the subject, issuer, SANs and dates and stores them alongside — it does not
decrypt anything itself. A `client_ca` whose certificate is not a CA is refused with `422 not_a_ca`,
and a CRL from another issuer with `422 crl_issuer_mismatch`.

An object larger than `CONTROLLER_STORE_MAX_BYTES` gives `413 blob_too_large` with the limit in
`max`.

## Inspectors

An inspector is a process that judges requests. The space keeps a catalogue of them: the name a
configuration refers to, the bus subject the process listens on, and the phases it works in.

| Endpoint | What it does |
| --- | --- |
| `GET /api/<scope>/inspectors` | the catalogue |
| `POST /api/<scope>/inspectors` | add one: `name`, `subject`, `phases`, `description`, `docs_url`, `log_level`, `conf` |
| `GET`, `PUT`, `DELETE /api/<scope>/inspectors/<uuid>` | one entry |
| `GET /api/<scope>/inspectors/declared` | which inspectors the configuration actually mentions, with the profile each mention uses and whether the catalogue knows it |
| `PUT /api/<scope>/inspectors/installed` | set the list of installed inspectors: `{"names":["ip","modsec"]}` |

`declared` is the answer to "what does this configuration expect to exist": it walks the space, the
servers and the locations, merges their inspector declarations and marks the unknown ones
`known: false`. Those are exactly what `config/send` refuses to compile.

`installed` is the other direction — which of the shipped inspectors this installation runs. An
inspector that a configuration still uses cannot leave: `409 inspector_in_use`, with the places
listed in `uses`. Deleting a catalogue entry that is in use fails the same way.

## Inspector profiles

Eight inspectors keep their settings in profiles, and all eight have the same endpoints. Replace
`<name>` with `auth`, `captcha`, `json`, `action`, `cookie`, `counter`, `vlai` or `rewrite`:

| Endpoint | What it does |
| --- | --- |
| `GET /api/<scope>/<name>/profiles` | all profiles of that inspector |
| `POST /api/<scope>/<name>/profiles` | create one: `{"name":"…","description":"…","doc":{…}}` |
| `GET`, `PUT`, `DELETE /api/<scope>/<name>/profiles/<uuid>` | one profile |
| `POST /api/<scope>/<name>/profiles/<uuid>/restore` | put the shipped `default` back as it came |
| `POST /api/<scope>/<name>/send` | publish this inspector's profiles |
| `GET /api/<scope>/<name>/desired` | the published generation |

`doc` is the profile itself, and its fields belong to that inspector — what the captcha profile
holds has nothing in common with what the rewrite profile holds. The panel builds its forms from the
same documents, and the help pages under **Protection** describe every field in words. A `doc` that
does not fit gives `400 invalid_profile`, and a reference inside it that does not resolve says which
one: `deny_response_unknown`, `schema_not_found`, `counter_unknown`, with the name in `detail`.

Every inspector has a `default` profile. It cannot be renamed (`400 default_name_locked`) or deleted
while it is the last one (`409 default_required`), and a profile a route still uses cannot be deleted
either (`409 in_use`). `modified: true` on `default` means it no longer matches what was shipped;
`restore` makes it match again.

Two inspectors have more than profiles.

**auth** also keeps the sources a profile logs users against:

| Endpoint | What it does |
| --- | --- |
| `GET`, `POST /api/<scope>/auth/sources` | sources: a file of users, LDAP, or another provider |
| `GET`, `PUT`, `DELETE /api/<scope>/auth/sources/<uuid>` | one source |
| `POST /api/<scope>/auth/user-line` | make one line for a file source |

`user-line` takes `{"login":"…","password":"…","groups":["admin"],"totp_store":"<uuid>"}` and returns
`{"line":"login:$2b$…:admin"}` — the password hashed with bcrypt, ready to paste into a user file.
The controller stores nothing: this is a helper, not a user registry. A password that is too weak is
refused with `400 weak_password`.

A source cannot be deleted while a profile uses it (`409 in_use`), and a profile whose source does
not exist is refused with `400 unknown_source`. A profile that gates by groups is also refused
(`409 fast_path_gated`) while a route still calls the inspector under an `if` condition: the
condition could skip the group check, so the gate would not hold.

**counter** also keeps the shared counters of the space:

| Endpoint | What it does |
| --- | --- |
| `GET /api/<scope>/counter/shared` | the shared counters |
| `PUT /api/<scope>/counter/shared` | replace them: `{"shared":[…]}` |

A counter that a profile still points at cannot disappear: `400 profile_reference_broken`.

## ModSecurity rules

| Endpoint | What it does |
| --- | --- |
| `GET`, `POST /api/<scope>/rule-files` | rule files; a file is `name`, `description` and `text_raw` |
| `GET`, `PUT`, `DELETE /api/<scope>/rule-files/<uuid>` | one file |
| `GET`, `POST /api/<scope>/rule-sets` | rule sets: which files and lists go together, plus the policy |
| `GET`, `PUT`, `DELETE /api/<scope>/rule-sets/<uuid>` | one set |
| `POST /api/<scope>/rule-sets/<uuid>/restore` | put the shipped `default` set back |
| `POST /api/<scope>/rules/compile` | compile without publishing; answers with counts and the hash |
| `POST /api/<scope>/rules/send` | compile and publish |
| `GET /api/<scope>/rules/desired` | the published generation: revision, hash, profile names |
| `GET /api/<scope>/rules/pack` | the whole published pointer, as the inspector reads it |

A file that a set includes cannot be deleted (`409 in_use`). `compile` is the safe way to check a
rule file before it reaches the node.

## IP lists, profiles and geo

| Endpoint | What it does |
| --- | --- |
| `GET`, `POST /api/<scope>/ip-sets` | IP sets: lists, countries and ASNs, with an `exclude` side and an `inverse` flag |
| `GET`, `PUT`, `DELETE /api/<scope>/ip-sets/<uuid>` | one set |
| `GET`, `POST /api/<scope>/ip-profiles` | IP profiles: ordered rules over those sets |
| `GET`, `PUT`, `DELETE /api/<scope>/ip-profiles/<uuid>` | one profile |
| `POST /api/<scope>/ip-profiles/<uuid>/restore` | put the shipped `default` back |
| `POST /api/<scope>/ip-profiles/send` | publish the profiles |
| `GET /api/<scope>/ip-profiles/desired`, `…/pack` | the published generation and the full pointer |
| `GET /api/<scope>/ip-countries` | countries with the size of each prefix list |
| `GET /api/<scope>/ip-countries/<uuid>/addresses` | its prefixes; `?q=` filters by address or prefix |
| `GET /api/<scope>/ip-countries/<uuid>/addresses/export` | the same as a text file |
| `GET /api/<scope>/ip-asns`, `…/<uuid>/addresses`, `…/export` | the same for autonomous systems |
| `POST /api/<scope>/geo/lookup/batch` | look up addresses: `{"addrs":["203.0.113.7"]}` |
| `POST /api/<scope>/geo/import/<kind>` | upload a MaxMind database, `kind` is `country` or `asn` |
| `GET /api/<scope>/geo/import` | the state of the import jobs |
| `GET /api/geo/files/<kind>` | the uploaded file: hash, size, build date, whether it is published |

Country and ASN prefixes are the only paged lists in the API: they take `page` (from zero) and
`page_size` (10 by default, 200 at most), and answer with `total`, `count`, `page`, `page_size` and
`page_count` beside the rows. `export` ignores paging and returns the whole list as a text
attachment. Everything else answers in full.

The upload is the raw file in the body, not a form:

```sh
curl -s -X POST --data-binary @GeoLite2-Country.mmdb \
  -H 'content-type: application/octet-stream' \
  "$API/geo/import/country"
```

It answers `202` and a job; the import runs in the background, and `GET geo/import` shows how far it
got — parsing, comparing, writing — and what changed. A file that is too large is `413 file_too_large`
with the limit in `detail`; an unknown `kind` is `404 unknown_kind`.

## Lists and addresses

A list, called a dataset, is a named set of values the node and the inspectors can read: addresses,
strings, the body of a page.

| Endpoint | What it does |
| --- | --- |
| `GET`, `POST /api/<scope>/datasets` | the lists of the space; create one |
| `GET`, `PUT`, `DELETE /api/<scope>/datasets/<uuid>` | one list |
| `GET /api/<scope>/datasets/<uuid>/addresses` | its entries; `?q=` keeps the ones containing that text |
| `POST /api/<scope>/datasets/<uuid>/addresses` | add entries: `address`, or `addresses`, or a whole `text`, with an optional `ttl_s` |
| `GET`, `PUT /api/<scope>/datasets/<uuid>/content` | the body of a `content` list, in base64 |
| `GET /api/<scope>/addresses?address=<value>` | find that exact value across every list of the space |
| `GET`, `DELETE /api/<scope>/addresses/<uuid>` | one entry |

`kind` is `list` or `content`; `type` says what a value looks like. An `active` list is live: it
lives in Redis, the node and the inspectors write into it at runtime, and an entry with `ttl_s`
disappears on its own. An `internal` list lives in the database and only changes when you change it.
Either way the API reads and writes the same way; `in_nginx: true` additionally compiles the list
into the node configuration, and that needs `config/send`.

Adding entries returns what was added and, on a bad value, `400 invalid_address` with the offending
values in `invalid`. A list another object references cannot be deleted (`409 in_use`), and a shipped
list cannot be renamed or removed (`400 builtin_locked`).

## Deny responses, body stores, log formats

| Endpoint | What it does |
| --- | --- |
| `GET`, `POST /api/<scope>/deny-responses` | what the node answers when a request is denied |
| `PUT`, `DELETE /api/<scope>/deny-responses/<uuid>` | one of them |
| `GET`, `POST /api/<scope>/body-stores` | where request bodies are archived |
| `PUT /api/<scope>/body-stores/<uuid>` | change one; a body store has no delete |
| `GET`, `POST /api/<scope>/log-formats` | nginx log formats |
| `PUT`, `DELETE /api/<scope>/log-formats/<uuid>` | one format |

A deny response comes back with `uses`: every place in the configuration that names it. A body
store answers with the archive address the controller is configured with in `url`, and the rest of
its settings in `spec`. A delete answers `{"ok":true}`, and a name that is already taken is
`409 name_taken`.

## Node configuration

| Endpoint | What it does |
| --- | --- |
| `GET /api/<scope>/config/preview` | the whole nginx configuration as text, as it stands now |
| `POST /api/<scope>/config/preview` | the same for a draft: `{"draft":{…},"node":{"kind":"server","uuid":"…"}}` |
| `POST /api/<scope>/config/send` | compile, check and publish |
| `GET /api/<scope>/config/desired` | the published generation |

`POST config/preview` is what the panel shows while you are still editing: it applies your unsaved
changes on top of what is stored and returns just that block, with `errors` and `warnings` instead of
a failure. Nothing is saved and nothing is published.

`config/send` refuses a configuration that would not work and says why:

```json
{
  "error": "validation_failed",
  "errors": [
    { "code": "auth_fast_path_gated", "message": "waf_inspect auth on shop.example.com / …" }
  ]
}
```

On success it answers with the new generation and the warnings it did not consider fatal — an action
nobody listens to, for instance.

## Node agent and balancer

| Endpoint | What it does |
| --- | --- |
| `GET`, `PUT /api/<scope>/agent` | node agent settings, with the hash of what they compile to |
| `POST /api/<scope>/agent/send` | publish them |
| `GET /api/<scope>/agent/desired` | the published generation |
| `GET`, `PUT /api/<scope>/haproxy` | balancer settings |
| `GET /api/<scope>/haproxy/preview` | the `haproxy.cfg` they compile to, as text |
| `POST /api/<scope>/haproxy/send` | publish them |
| `GET /api/<scope>/haproxy/desired` | the published generation |

A send that changes nothing keeps the revision it had and simply confirms the generation.

## Audit and logs

The search endpoints are a thin proxy to the search service, which reads what the logger wrote.

| Endpoint | What it gives |
| --- | --- |
| `GET /api/search/audit` | audit records: one per inspected request |
| `GET /api/search/audit/groups` | the same, grouped |
| `GET /api/search/audit/<node>/<ray>` | one record by node and ray id |
| `GET /api/search/audit/<node>/<ray>/<part>` | one part of it: `inspectors`, `findings`, `headers`, `args`, `body` |
| `GET /api/search/findings` | what the inspectors found |
| `GET /api/search/logs` | service logs |
| `GET /api/search/logs/facets` | the values the log filters offer |

The query string is passed through untouched, and so is the answer. If the search service is not
configured the answer is `503 search_disabled`; if it does not respond in 15 seconds,
`503 search_unreachable`.

## Recipes

Find the space and look at what is installed:

```sh
API=http://127.0.0.1:8080/api
SCOPE=$(curl -s $API/spaces | jq -r '.spaces[0].uuid')

curl -s $API/$SCOPE/catalog | jq '{inspectors:[.inspectors[].name], profiles:[.profiles[].name]}'
```

Turn protection on for one location and put it on the node:

```sh
LOC=$(curl -s "$API/$SCOPE/locations?server=$SERVER" | jq -r '.locations[0].uuid')

curl -s -X PUT $API/$SCOPE/locations/$LOC \
  -H 'content-type: application/json' \
  -d '{"waf":{"enabled":true}}'

curl -s $API/$SCOPE/config/preview          # the whole nginx config as text
curl -s -X POST $API/$SCOPE/config/send     # compile, check, publish
```

Ban an address for an hour:

```sh
DS=$(curl -s $API/$SCOPE/datasets | jq -r '.datasets[] | select(.name=="shop-banned") | .uuid')

curl -s -X POST $API/$SCOPE/datasets/$DS/addresses \
  -H 'content-type: application/json' \
  -d '{"address":"203.0.113.7","ttl_s":3600}'
```

Watch the delivery until everything agrees:

```sh
curl -s $API/$SCOPE/convergence | jq '{lamp, channels: [.channels[] | {id, state}]}'
```

```json
{ "lamp": "green", "channels": [ { "id": "nginx", "state": "ok" }, { "id": "rules", "state": "ok" } ] }
```

A channel stays `stale` while a process still runs the previous generation, and turns `failed` if it
tried and could not. `GET /api/fleet` says which process it is.

Publish everything after a batch of changes:

```sh
for ch in config rules ip-profiles auth captcha json action cookie counter vlai rewrite agent haproxy; do
  curl -s -X POST $API/$SCOPE/$ch/send >/dev/null
done
```

A send with nothing to publish is harmless: the generation and its revision stay as they were.

## Every endpoint

One list to grep. Details are in the sections above.

| Method | Path |
| --- | --- |
| `GET` | `/healthz` |
| `GET` | `/api/health` |
| `GET` | `/api/meta` |
| `GET` | `/api/actions` |
| `GET` | `/api/fleet` |
| `POST` | `/api/fleet/forget` |
| `GET` | `/api/geo/files/<kind>` |
| `GET` | `/api/log-levels` |
| `PUT` | `/api/log-levels` |
| `GET` | `/api/search/audit` |
| `GET` | `/api/search/audit/<node>/<ray>` |
| `GET` | `/api/search/audit/<node>/<ray>/args` |
| `GET` | `/api/search/audit/<node>/<ray>/body` |
| `GET` | `/api/search/audit/<node>/<ray>/findings` |
| `GET` | `/api/search/audit/<node>/<ray>/headers` |
| `GET` | `/api/search/audit/<node>/<ray>/inspectors` |
| `GET` | `/api/search/audit/groups` |
| `GET` | `/api/search/findings` |
| `GET` | `/api/search/logs` |
| `GET` | `/api/search/logs/facets` |
| `GET` | `/api/spaces` |
| `GET` | `/api/<scope>/action/desired` |
| `GET` | `/api/<scope>/action/profiles` |
| `POST` | `/api/<scope>/action/profiles` |
| `GET` | `/api/<scope>/action/profiles/<uuid>` |
| `PUT` | `/api/<scope>/action/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/action/profiles/<uuid>` |
| `POST` | `/api/<scope>/action/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/action/send` |
| `GET` | `/api/<scope>/addresses` |
| `GET` | `/api/<scope>/addresses/<uuid>` |
| `DELETE` | `/api/<scope>/addresses/<uuid>` |
| `GET` | `/api/<scope>/agent` |
| `PUT` | `/api/<scope>/agent` |
| `GET` | `/api/<scope>/agent/desired` |
| `POST` | `/api/<scope>/agent/send` |
| `GET` | `/api/<scope>/auth/desired` |
| `GET` | `/api/<scope>/auth/profiles` |
| `POST` | `/api/<scope>/auth/profiles` |
| `GET` | `/api/<scope>/auth/profiles/<uuid>` |
| `PUT` | `/api/<scope>/auth/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/auth/profiles/<uuid>` |
| `POST` | `/api/<scope>/auth/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/auth/send` |
| `GET` | `/api/<scope>/auth/sources` |
| `POST` | `/api/<scope>/auth/sources` |
| `GET` | `/api/<scope>/auth/sources/<uuid>` |
| `PUT` | `/api/<scope>/auth/sources/<uuid>` |
| `DELETE` | `/api/<scope>/auth/sources/<uuid>` |
| `POST` | `/api/<scope>/auth/user-line` |
| `GET` | `/api/<scope>/captcha/desired` |
| `GET` | `/api/<scope>/captcha/profiles` |
| `POST` | `/api/<scope>/captcha/profiles` |
| `GET` | `/api/<scope>/captcha/profiles/<uuid>` |
| `PUT` | `/api/<scope>/captcha/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/captcha/profiles/<uuid>` |
| `POST` | `/api/<scope>/captcha/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/captcha/send` |
| `GET` | `/api/<scope>/catalog` |
| `GET` | `/api/<scope>/certificates` |
| `POST` | `/api/<scope>/certificates` |
| `GET` | `/api/<scope>/certificates/<uuid>` |
| `DELETE` | `/api/<scope>/certificates/<uuid>` |
| `PUT` | `/api/<scope>/certificates/<uuid>/crl` |
| `DELETE` | `/api/<scope>/certificates/<uuid>/crl` |
| `GET` | `/api/<scope>/config/desired` |
| `GET` | `/api/<scope>/config/preview` |
| `POST` | `/api/<scope>/config/preview` |
| `POST` | `/api/<scope>/config/send` |
| `GET` | `/api/<scope>/content-types` |
| `GET` | `/api/<scope>/convergence` |
| `POST` | `/api/<scope>/convergence/refresh` |
| `GET` | `/api/<scope>/cookie/desired` |
| `GET` | `/api/<scope>/cookie/profiles` |
| `POST` | `/api/<scope>/cookie/profiles` |
| `GET` | `/api/<scope>/cookie/profiles/<uuid>` |
| `PUT` | `/api/<scope>/cookie/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/cookie/profiles/<uuid>` |
| `POST` | `/api/<scope>/cookie/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/cookie/send` |
| `GET` | `/api/<scope>/counter/desired` |
| `GET` | `/api/<scope>/counter/profiles` |
| `POST` | `/api/<scope>/counter/profiles` |
| `GET` | `/api/<scope>/counter/profiles/<uuid>` |
| `PUT` | `/api/<scope>/counter/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/counter/profiles/<uuid>` |
| `POST` | `/api/<scope>/counter/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/counter/send` |
| `GET` | `/api/<scope>/counter/shared` |
| `PUT` | `/api/<scope>/counter/shared` |
| `GET` | `/api/<scope>/crypto` |
| `GET` | `/api/<scope>/datasets` |
| `POST` | `/api/<scope>/datasets` |
| `GET` | `/api/<scope>/datasets/<uuid>` |
| `PUT` | `/api/<scope>/datasets/<uuid>` |
| `DELETE` | `/api/<scope>/datasets/<uuid>` |
| `GET` | `/api/<scope>/datasets/<uuid>/addresses` |
| `POST` | `/api/<scope>/datasets/<uuid>/addresses` |
| `GET` | `/api/<scope>/datasets/<uuid>/content` |
| `PUT` | `/api/<scope>/datasets/<uuid>/content` |
| `POST` | `/api/<scope>/geo/lookup/batch` |
| `GET` | `/api/<scope>/geo/import` |
| `POST` | `/api/<scope>/geo/import/<kind>` |
| `GET` | `/api/<scope>/haproxy` |
| `PUT` | `/api/<scope>/haproxy` |
| `GET` | `/api/<scope>/haproxy/desired` |
| `GET` | `/api/<scope>/haproxy/preview` |
| `POST` | `/api/<scope>/haproxy/send` |
| `GET` | `/api/<scope>/http` |
| `PUT` | `/api/<scope>/http` |
| `GET` | `/api/<scope>/http/inheritance` |
| `GET` | `/api/<scope>/inspectors` |
| `POST` | `/api/<scope>/inspectors` |
| `GET` | `/api/<scope>/inspectors/<uuid>` |
| `PUT` | `/api/<scope>/inspectors/<uuid>` |
| `DELETE` | `/api/<scope>/inspectors/<uuid>` |
| `GET` | `/api/<scope>/inspectors/declared` |
| `PUT` | `/api/<scope>/inspectors/installed` |
| `GET` | `/api/<scope>/ip-asns` |
| `GET` | `/api/<scope>/ip-asns/<uuid>` |
| `GET` | `/api/<scope>/ip-asns/<uuid>/addresses` |
| `GET` | `/api/<scope>/ip-asns/<uuid>/addresses/export` |
| `GET` | `/api/<scope>/ip-countries` |
| `GET` | `/api/<scope>/ip-countries/<uuid>` |
| `GET` | `/api/<scope>/ip-countries/<uuid>/addresses` |
| `GET` | `/api/<scope>/ip-countries/<uuid>/addresses/export` |
| `GET` | `/api/<scope>/ip-profiles` |
| `POST` | `/api/<scope>/ip-profiles` |
| `GET` | `/api/<scope>/ip-profiles/<uuid>` |
| `PUT` | `/api/<scope>/ip-profiles/<uuid>` |
| `DELETE` | `/api/<scope>/ip-profiles/<uuid>` |
| `POST` | `/api/<scope>/ip-profiles/<uuid>/restore` |
| `GET` | `/api/<scope>/ip-profiles/desired` |
| `GET` | `/api/<scope>/ip-profiles/pack` |
| `POST` | `/api/<scope>/ip-profiles/send` |
| `GET` | `/api/<scope>/ip-sets` |
| `POST` | `/api/<scope>/ip-sets` |
| `GET` | `/api/<scope>/ip-sets/<uuid>` |
| `PUT` | `/api/<scope>/ip-sets/<uuid>` |
| `DELETE` | `/api/<scope>/ip-sets/<uuid>` |
| `GET` | `/api/<scope>/json/desired` |
| `GET` | `/api/<scope>/json/profiles` |
| `POST` | `/api/<scope>/json/profiles` |
| `GET` | `/api/<scope>/json/profiles/<uuid>` |
| `PUT` | `/api/<scope>/json/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/json/profiles/<uuid>` |
| `POST` | `/api/<scope>/json/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/json/send` |
| `GET` | `/api/<scope>/locations` |
| `GET` | `/api/<scope>/locations/<uuid>` |
| `PUT` | `/api/<scope>/locations/<uuid>` |
| `DELETE` | `/api/<scope>/locations/<uuid>` |
| `GET` | `/api/<scope>/locations/<uuid>/inheritance` |
| `GET` | `/api/<scope>/ports` |
| `POST` | `/api/<scope>/ports` |
| `GET` | `/api/<scope>/ports/<uuid>` |
| `PUT` | `/api/<scope>/ports/<uuid>` |
| `DELETE` | `/api/<scope>/ports/<uuid>` |
| `GET` | `/api/<scope>/rewrite/desired` |
| `GET` | `/api/<scope>/rewrite/profiles` |
| `POST` | `/api/<scope>/rewrite/profiles` |
| `GET` | `/api/<scope>/rewrite/profiles/<uuid>` |
| `PUT` | `/api/<scope>/rewrite/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/rewrite/profiles/<uuid>` |
| `POST` | `/api/<scope>/rewrite/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/rewrite/send` |
| `GET` | `/api/<scope>/rule-files` |
| `POST` | `/api/<scope>/rule-files` |
| `GET` | `/api/<scope>/rule-files/<uuid>` |
| `PUT` | `/api/<scope>/rule-files/<uuid>` |
| `DELETE` | `/api/<scope>/rule-files/<uuid>` |
| `GET` | `/api/<scope>/rule-sets` |
| `POST` | `/api/<scope>/rule-sets` |
| `GET` | `/api/<scope>/rule-sets/<uuid>` |
| `PUT` | `/api/<scope>/rule-sets/<uuid>` |
| `DELETE` | `/api/<scope>/rule-sets/<uuid>` |
| `POST` | `/api/<scope>/rule-sets/<uuid>/restore` |
| `POST` | `/api/<scope>/rules/compile` |
| `GET` | `/api/<scope>/rules/desired` |
| `GET` | `/api/<scope>/rules/pack` |
| `POST` | `/api/<scope>/rules/send` |
| `GET` | `/api/<scope>/servers` |
| `POST` | `/api/<scope>/servers` |
| `GET` | `/api/<scope>/servers/<uuid>` |
| `PUT` | `/api/<scope>/servers/<uuid>` |
| `DELETE` | `/api/<scope>/servers/<uuid>` |
| `GET` | `/api/<scope>/servers/<uuid>/certificates` |
| `POST` | `/api/<scope>/servers/<uuid>/certificates` |
| `DELETE` | `/api/<scope>/servers/<uuid>/certificates/<bind-uuid>` |
| `GET` | `/api/<scope>/servers/<uuid>/inheritance` |
| `GET` | `/api/<scope>/servers/<uuid>/locations` |
| `POST` | `/api/<scope>/servers/<uuid>/locations` |
| `PUT` | `/api/<scope>/servers/<uuid>/locations/order` |
| `GET` | `/api/<scope>/servers/<uuid>/ports` |
| `POST` | `/api/<scope>/servers/<uuid>/ports` |
| `PUT` | `/api/<scope>/servers/<uuid>/ports/<bind-uuid>` |
| `DELETE` | `/api/<scope>/servers/<uuid>/ports/<bind-uuid>` |
| `GET` | `/api/<scope>/store` |
| `POST` | `/api/<scope>/store` |
| `GET` | `/api/<scope>/store/<uuid>` |
| `GET` | `/api/<scope>/store/<uuid>/blob` |
| `GET` | `/api/<scope>/store/<uuid>/meta` |
| `GET` | `/api/<scope>/upstreams` |
| `POST` | `/api/<scope>/upstreams` |
| `GET` | `/api/<scope>/upstreams/<uuid>` |
| `PUT` | `/api/<scope>/upstreams/<uuid>` |
| `DELETE` | `/api/<scope>/upstreams/<uuid>` |
| `GET` | `/api/<scope>/vlai/desired` |
| `GET` | `/api/<scope>/vlai/profiles` |
| `POST` | `/api/<scope>/vlai/profiles` |
| `GET` | `/api/<scope>/vlai/profiles/<uuid>` |
| `PUT` | `/api/<scope>/vlai/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/vlai/profiles/<uuid>` |
| `POST` | `/api/<scope>/vlai/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/vlai/send` |
| `WS` | `/agent_health_socket` |
