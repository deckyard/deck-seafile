<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/seafile

A client for the Web API of a self-hosted [Seafile](https://www.seafile.com/)
server (`/api2` and `/api/v2.1`). Typed functions cover server and account
info; libraries (list, create incl. encrypted, rename, remove, decrypt);
files and folders (list, detail, mkdir, download, upload, resumable upload,
update, rename, copy, move, remove, lock, history, revert); background copy
and move; user and group shares, libraries shared with the account; starred
items; share and upload links; the trash; library API tokens; search. `call` reaches any other endpoint.

Plain file sync does not need this deck: Seafile speaks WebDAV at
`/seafdav`, which the interpreter's `webdav` module reaches. This deck covers
what WebDAV cannot: libraries, links, shares, history, the trash, tokens.

## Conventions

Snippets assume this preamble:

```jennifer
use fs;
use io;
use json;
use os;
use time;
import "@deckyard/seafile/" as seafile;

def c as seafile.Client init seafile.client("https://cloud.example.com");
$c = seafile.withToken($c, os.getEnv("SEAFILE_TOKEN"));
io.printf("%s\n", seafile.account($c).email);
```

Snippets also use `$id` and `$other` for library ids (`Library.id`), `$data`
for a `bytes` value and `$token` for an account token.

A `Client` is a value. `withToken` and the other `with*` functions return a
changed copy, so assign the result back to `$c`.

Files are addressed by a library id and an absolute path in that library:
`seafile.fileDetail($c, $lib.id, "/docs/a.txt")`. Times are seconds since
the epoch; the server's ISO 8601 strings are converted.

Seafile auto-renames instead of refusing: `mkdir` without `parents`,
`rename`, `put` without `replace`, `copy` and `move` give a taken name a free
one (`a (1).txt`). `mkdir` and `rename` return the path the item got, `put`
an `Entry` with it.

## Errors

Every failure is a `seafile.SeafileError` (kind `"seafile"`), except a reached
cap: a body over its limit or a paged walk past its page limit is
`Error{kind: "limit"}`. The `status` field holds the HTTP status of a refusal
(0 otherwise). A refusal names the request, the HTTP status and the server's
reason (`error_msg`, `detail`, `error` or
`non_field_errors`):

```text
seafile: GET /api/v2.1/repos/63b9.../file/?p=%2Fmissing: HTTP 404: File /missing not found.
seafile: POST /api2/auth-token/: HTTP 400: Unable to login with provided credentials.
seafile: a path has no empty, . or .. segments, got "/a/../b"
```

Bad input (a relative path, a `..` segment, a library id that is not a UUID,
credentials over `http://` to a host that is not loopback without
`withPlainHttp`) is refused before anything is sent; a transfer link on a foreign origin is refused before the
transfer. An error message names a `/seafhttp/` link without its token.

## Limits

Bodies are held in memory: `get` reads the whole file (capped by
`maxBytes`), `put` and `putResumable` send it from a `bytes` value. The
interpreter's `http` module does not stream yet.

## Requirements

Jennifer 0.26.0 or newer, the default `jennifer` binary (not
`jennifer-tiny`), and the `net` capability. Tested against Seafile 13.0
Community Edition; `lockFile`, `unlockFile` and `search` need the
Professional edition.
