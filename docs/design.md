<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

The deck is a client for the Web API (`/api2` and `/api/v2.1`) of a
self-hosted Seafile™ server: server and account info; libraries, encrypted
ones included; files and folders by library id and path (list, detail,
mkdir, download, upload, resumable chunked upload, update, rename, copy,
move, remove, lock, history, revert); async batch copy and move; user and
group shares and libraries shared with the account; starred items; share
and upload links; the trash (list, restore, clean); library API tokens;
search. `call` reaches any other endpoint. It needs the `net` capability
and runs on the default binary only.

Out of scope:

- **File sync.** That is WebDAV (`/seafdav`), which the bundled `webdav`
  module covers.
- **The admin API, wikis, notifications and OCM.**
- **Streaming transfers.** Bodies are held in memory; `get` refuses a file
  over `DOWNLOAD_LIMIT` (64 MiB) unless the caller passes a larger cap.

## Decisions

- **The API reference and the server source.** The reference
  (seafile-api.readme.io, v13.0) only indexes many routes, so the seahub and
  fileserver sources settled the rest, and every verb was checked against a
  live server.
- **Two kinds of token.** An account token (`login`, with an optional
  two-factor code, or `withToken`) is sent as `Bearer`, or as `Token` with
  `withLegacyAuth` for servers before 11.0. A library API token
  (`withRepoToken`) uses the `via-repo-token` endpoints and is limited to
  one library; verbs those endpoints lack are refused locally.
- **Transfers take two steps.** The API hands out an upload or download
  link, and the `/seafhttp/...` URL carries its own token, so no
  `Authorization` header goes there. A link on another origin than the base
  URL is refused unless `withFileServer` names that origin.
- **Seafile renames instead of refusing.** `mkdir`, `rename`, `put` without
  `replace`, `copy` and `move` pick `x (1)` when the name is taken, so the
  verbs return the name actually stored. `mkdir` with parents is
  idempotent; a library-token client emulates it level by level and throws
  when a file is in the way.
- **Missing is a 404 about a file or folder.** `exists` and `rename` treat
  a 404 whose reason names a file or folder as "missing", but not
  `Library not found.`; they try the file endpoint first, then the folder
  endpoint.
- **Resumable upload follows the fileserver's rules.** `putResumable`
  sends chunks with `Content-Range` to one reusable upload link. The server
  keeps one temporary file per library and path and accepts a chunk only at
  its current size, without checking the content, so a stale temporary file
  would join silently. With an account token the deck asks for the offset
  first, drops a temporary file it should not resume, and restarts once
  after a first-chunk 400. A library token cannot ask or drop, so it falls
  back to one plain upload after a 400.
- **Dropping a stale temporary file.** `put` and `update` with an account
  token drop a temporary file of the same path first: one byte at its
  offset to the folder's update link with an impossible head commit, which
  makes both fileservers (C and Go) delete the temporary file and store
  nothing. It is best effort for `put` and `update`; `putResumable` lets a
  failure throw. The temporary file is keyed by library and path, not by
  user, so a drop aborts anyone else's chunked upload of that path. Library
  tokens cannot drop; their temporary files expire on the server.
- **Upload names.** The C and Go fileservers read multipart file names
  differently (the C one takes everything between the first and last `"`
  without unescaping, the Go one unescapes). A name with `"` therefore goes
  through the chunked path, whose percent-encoded header both servers
  decode, and a name with `\` is refused (the C server would store only the
  part after it).
- **Strict ranges, tolerant reading.** Offsets outside 0 to 2^53 are an
  error; the JSON readers accept numbers as numbers or strings, booleans as
  `true`, `"true"` or 1, and times as epoch seconds or ISO 8601, because
  the API mixes them.
- **Paged walks stop safely.** `trashAll` and `fileHistory` stop at the end
  marker, an empty page or a cursor seen before, and refuse to go past
  `MAX_PAGES`. History pages end at a rename, and the next page asks for the
  old path.
- **Share permissions as seahub accepts them**: `r`, `rw`, `admin`, the Pro
  values `preview`, `cloud-edit` and `invisible`, and `custom-<id>`, more
  than the reference lists (`SHARE_PERMISSIONS`).
- **Zero values allow.** `ShareLinkOptions.noDownload` rather than
  `canDownload`, so a zero-value options struct allows downloads.
- **Names.** `list` and `task` are keywords, so the listing is `listDir`.

## Errors

Every failure of kind `"seafile"` (`ERROR_KIND`) is a `SeafileError` with
`status`, the HTTP status of a refusal (0 for a local check or a malformed
reply). A refusal names the request, the status and
the server's reason, read from whichever shape the endpoint uses
(`error_msg`, `detail`, `error`, `non_field_errors` or a bare string; the
fileserver's error text is not valid JSON and is cleaned before decoding).

Generic kinds:

- a body over its cap, or a paged walk past `MAX_PAGES`, is kind
  `"limit"`;
- a server that cannot be reached is the transport's `net.NetError` (kind
  `"net"`), passed on unchanged with `reason`, `op`, `sent` and `replied`;
  should its message ever hold a transfer link, the link is shortened so
  its token does not show;
- a reply that does not come in time is kind `"timeout"`, a connection
  closed mid-reply `"closed"`, a cancelled task `"cancelled"`, all passed on
  unchanged; a reply nested past the JSON decoder's cap is kind `"limit"`.

## Security and limits

- Credentials and transfer links go over plain `http://` only to a loopback
  host or after `withPlainHttp`. The check reads the parsed, lower-cased
  scheme and host, so `HTTP://` counts as plain too, and it runs for the
  base URL at every request, for the password in `login`, and for every
  transfer link.
- URLs are checked strictly (scheme, host characters, port range, nothing
  between the host and the port or path, no user info, no spaces or control
  characters); a URL `uri.parse` refuses (newer interpreters throw kind
  `"uri"` for a bad port or IP literal) is kind `"seafile"` too. Paths refuse empty, `.` and `..`
  segments; library ids must be UUIDs; app names refuse `.` and `..` so a
  proxy that folds dots cannot redirect a route.
- Error messages name a `/seafhttp/` link without its token.
- Replies are capped at `REPLY_LIMIT` (64 MiB, `withReplyLimit`),
  downloads at `DOWNLOAD_LIMIT`, paged walks at `MAX_PAGES`; GET retries
  are bounded by `MAX_RETRIES`, writes are never retried.
- Certificates are checked unless `withInsecure`; `withCaCert` adds a
  private CA.

## Testing and validation

- The overlay runs every verb against a loopback fake that serves both the
  API and `/seafhttp` links on one listener and records what it received,
  so the tests check what is sent (routes, encoded queries, JSON, form and
  multipart bodies, chunk ranges, no `Authorization` on transfer links) as
  well as the parsing.
- Transport failures are tested against a closed loopback port, for an API
  request and for a transfer link.
- Validated live on 2026-11-06 against Seafile 13.0.29 Community Edition in
  Docker™ over loopback HTTP: every export except `search` and
  `lockFile` / `unlockFile` (Pro only; Community answers 403) and the
  legacy `Token` scheme against a server before 11.0. Both examples ran.
  The upload and temporary-file fixes were re-tested live on the C
  fileserver (the default) and the Go fileserver.
- The examples need a server and a token, so the gate only parses them.

Not covered: 429 back-off, TLS (`withCaCert`, `withInsecure`), a real
two-factor code, the race that answers a first chunk 400, and an update
link refused for lack of an edit permission (needs a Pro custom
permission).

## Known limitations and open questions

- A decomposed (NFD) file name never resumes and never drops: the
  fileserver keys the temporary file by the NFC form while the offset query
  looks up the raw name, and Jennifer has no NFC normalization.
- `sharedWithMe` cannot report the sharer's name, group or admin flag:
  Seafile 13 does not serialize them.
- A drop of a temporary file aborts another client's chunked upload of the
  same path; this is inherent in how the fileserver keys temporary files.
- Share-link passwords shorter than the server's minimum (10 by default)
  are refused by the server, not checked locally.
- Accounts created by the admin API get a virtual id
  (`<hex>@auth.local`), which shares and group membership need instead of
  the contact e-mail.

## Dependencies on the interpreter

- The bundled `http`, `multipart` and `uri` modules; `http`'s body-only
  `maxBytes` cap.
- `json.typeOf` returning `missing` for an unresolved pointer (0.26.0).
- Floor `>=0.27.0`: the UTF-8 codecs of `encoding.encode` / `decode` and
  `strings.replicate` arrived in 0.27.0.
- Thrown error structs and lint's L104 for `SeafileError`; caps as kind
  `"limit"`.
- `net.NetError` and the `"net"` kind (`jennifer`'s M28.65, transport
  errors have their own kind).
