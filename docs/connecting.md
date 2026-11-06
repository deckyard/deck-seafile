<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Getting started

## The address

`client` takes the server's URL (`SERVICE_URL`). A bare host gets
`https://`; trailing `/`, `/api2` and `/api/v2.1` are dropped, a sub-path
(`SITE_ROOT`) is kept:

```jennifer
def c as seafile.Client init seafile.client("https://cloud.example.com");
def sub as seafile.Client init seafile.client("https://example.com/seafile");
```

`client` throws for a URL with a query, a fragment or a user, a scheme other
than `http` or `https`, no host, or a port outside 1-65535.

`withCaCert` trusts a server's own CA; `withInsecure` turns certificate
checking off. `serverInfo` needs no credentials and checks the address:

```jennifer
io.printf("%s\n", seafile.serverInfo($c).version);
```

## Account tokens

`login` trades a user name and password for an account token. With
two-factor authentication pass the current code as `otp` (sent as
`X-SEAFILE-OTP`), else `""`. The token acts as the account on every endpoint
and stays valid until it is revoked (Settings > Devices).

```jennifer
def token as string init seafile.login($c, "me@example.com", os.getEnv("SEAFILE_PASSWORD"), "");
$c = seafile.withToken($c, $token);
def a as seafile.Account init seafile.account($c);
io.printf("%s: %d of %d bytes\n", $a.email, $a.usage, $a.total);
```

`Account.total` is -2 for an unlimited quota. `usage` and `total` take the
leading digits of a string (`"22020651,"`, as the reference shows them).

Requests carry `Authorization: Bearer <token>`. Servers before 11.0 want
`Token <token>`: `withLegacyAuth` switches. Seafile 13 accepts both.

Credentials go over plain `http://` only to a loopback host (`localhost`,
`127.0.0.0/8`, `[::1]`). For any other `http://` host each request (and
`login`) throws before it connects; `withPlainHttp` lifts that:

```jennifer
def lan as seafile.Client init seafile.withPlainHttp(seafile.withToken(seafile.client("http://seafile.lan"), $token));
```

## Library API tokens

A library API token opens one library only, with `r` or `rw` permission. A
library admin makes one with `createApiToken` (or in the library's "API
Token" dialog). `withRepoToken` points the client at the
`/api/v2.1/via-repo-token/` endpoints:

```jennifer
def t as seafile.ApiToken init seafile.createApiToken($c, $lib.id, "backup job", "rw");
def r as seafile.Client init seafile.withRepoToken(seafile.client("https://cloud.example.com"),
    $t.repoId, $t.token);
io.printf("%s\n", seafile.tokenLibrary($r).name);
seafile.put($r, $t.repoId, "/nightly.tar", $data, true);
```

Such a client reaches `listDir`, `fileDetail`, `exists`, `mkdir`, `get`,
`put`, `putResumable`, `rename`, `copy`, `move`, `copyItems`, `moveItems`,
`remove`, `removeItems`, `lockFile`, `unlockFile`, `revertFile`, `revertDir`,
`createShareLink` and `tokenLibrary`, plus `serverInfo` and `call` (for other
`/api/v2.1/via-repo-token/` routes); every other verb throws before sending.
The verbs still take a library id, which is never sent: `""` always passes,
and another id must equal the one given to `withRepoToken` (unless that was
`""`). `putResumable` cannot resume with such a token (the offset endpoint is
account-only): it starts at 0 and falls back to `put`, one POST of the whole
data, when the first chunk answers HTTP 400 (a temp file of an interrupted
upload; a name with `"` throws instead). `createShareLink`
takes no password or expiry.

## Transfer links

Downloads and uploads take two steps: the API hands out a link
(`/seafhttp/files/<token>/...`, `/seafhttp/upload-api/<token>`), then the
deck fetches or posts to it. The link carries its own token: no
`Authorization` header goes there.

The link's origin (scheme, host, port) must equal the base URL's. A server
with a misconfigured `SERVICE_URL` or `FILE_SERVER_ROOT` hands out links to
another host, port or to `http://`; those are refused. A file server on its
own origin is allowed with `withFileServer`:

```jennifer
$c = seafile.withFileServer($c, "https://files.example.com:8082");
```

A link to a non-loopback `http://` host needs `withPlainHttp`, as
credentials do.

## Any endpoint

`call` takes a method (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`), the full
path under the base URL (`/api2/...` or `/api/v2.1/...`) with its query
string, and the body as JSON text, sent as `application/json`; endpoints that
read only a form body are out of its reach:

```jennifer
def limit as json.Value init seafile.call($c, "GET", "/api2/repos/" + $id + "/history-limit/", "");
seafile.call($c, "PUT", "/api2/repos/" + $id + "/history-limit/", '{"keep_days":30}');
```

## Timeouts, retries and reply size

`withTimeout` sets each request's idle timeout, 30 s by default; a negative
value throws. `withRetries` retries API GETs answered 429 or 5xx, waiting
500 ms, then twice as long each time, or longer for a `Retry-After` in
seconds, at most 30 s. It takes 0 to `MAX_RETRIES` (10). Writes and
transfers are never retried.

Every reply body but `get`'s is refused over `REPLY_LIMIT` (64 MiB).
`withReplyLimit` sets another cap, or none with a negative value. A
recursive listing of a large library is the reply most likely to need it:

```jennifer
$c = seafile.withReplyLimit($c, 256 * 1024 * 1024);
```
