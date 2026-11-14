<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# seafile cheatsheet

Every export of `@deckyard/seafile`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/seafile/" as seafile;
```

Every function that sends a request throws a `SeafileError` (kind `"seafile"`)
when it fails, or `Error{kind: "limit"}` when a body or a paged walk passes its
cap. A `repoId` is a library id (a UUID) from `libraries`; a `path` is
absolute in its library (`/docs/a.txt`, `/` for the root). Times are seconds
since the epoch. "Account" marks a verb a library API token client
(`withRepoToken`) refuses before sending anything.

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `ERROR_KIND` | `"seafile"` | the `kind` of every error the deck throws |
| `DOWNLOAD_LIMIT` | `67108864` | the largest file `get` accepts with `maxBytes` 0 (64 MiB) |
| `REPLY_LIMIT` | `67108864` | the largest reply body of every other request with `Client.replyLimit` 0 (64 MiB) |
| `MAX_RETRIES` | `10` | the most retries `withRetries` accepts |
| `MAX_PAGES` | `1000` | pages `trashAll` and `fileHistory` follow before they refuse |
| `CHUNK_SIZE` | `8388608` | the chunk size of `putResumable` with `chunkSize` 0 (8 MiB) |
| `LIBRARY_TYPES` | `["mine", "shared", "group", "org"]` | the `type` filters of `libraries` |
| `SHARE_PERMISSIONS` | `["r", "rw", "admin", "preview", "cloud-edit", "invisible"]` | the permissions of `share` and `changeShare` besides `custom-<id>`; the last three need Professional |
| `TOKEN_PERMISSIONS` | `["r", "rw"]` | the permissions of a library API token |

## Types

A literal of a deck struct names every field, so build `ShareLinkOptions`
and `SearchOptions` from the zero value: `def o as seafile.ShareLinkOptions;`
then set fields.

### `SeafileError`

Every error of kind `"seafile"`.

| Field | Meaning |
|---|---|
| `kind as string` | always `"seafile"` |
| `message as string` | `seafile: <request>: HTTP <status>: <reason>`, or what went wrong |
| `status as int` | the HTTP status the server answered (440 a locked file, 443 over quota, ...); 0 when the failure is not a refused request |

### `Client`

| Field | Meaning |
|---|---|
| `url as string` | `http[s]://host[:port][/path]`, without `/api2` |
| `token as string` | the account or library API token; `""` for none |
| `legacyAuth as bool` | send `Token <t>` instead of `Bearer <t>` |
| `repoToken as bool` | `token` is a library API token |
| `repoId as string` | the token's library; `""` for unchecked |
| `fileServer as string` | a further origin transfer links may use, `scheme://host:port`; `""` for none |
| `tls as http.TlsOptions` | certificate checking |
| `timeoutMs as int` | idle timeout per request; 0 for 30 s, never negative |
| `retries as int` | retries of a GET answered 429 or 5xx, 0 to `MAX_RETRIES` |
| `replyLimit as int` | the largest reply body of every request but `get`; 0 for `REPLY_LIMIT`, negative for none |
| `plainHttp as bool` | send credentials and transfer tokens over `http://` to a host that is not loopback |

Build a `Client` with `client` and the `with*` functions, not a literal.

### `ServerInfo`

| Field | Meaning |
|---|---|
| `version as string` | e.g. `13.0.29` |
| `encryptedLibraryVersion as int` | the version new encrypted libraries get |
| `features as list of string` | e.g. `seafile-basic`, `seafile-pro` |

### `Account`

| Field | Meaning |
|---|---|
| `email as string` | the user id: an e-mail address or `x@auth.local` |
| `name as string` | the display name |
| `loginId as string` | the login id; often `""` |
| `contactEmail as string` | the contact address |
| `institution as string` | the institution |
| `department as string` | the department |
| `isStaff as bool` | whether the account is a system admin |
| `usage as int` | bytes used |
| `total as int` | the quota in bytes; -2 for unlimited |

### `Library`

| Field | Meaning |
|---|---|
| `id as string` | the library id |
| `name as string` | the name |
| `type as string` | `repo`, `srepo` (shared with the account), `grepo` (group); `""` when not reported |
| `owner as string` | the owner's user id |
| `size as int` | bytes |
| `mtime as int` | the last change |
| `encrypted as bool` | whether it is encrypted |
| `permission as string` | `r` or `rw` |

### `Entry`

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `path as string` | the path in its library |
| `type as string` | `file` or `dir` |
| `id as string` | the object id; all zeros for an empty file or folder |
| `size as int` | bytes; 0 for a folder |
| `mtime as int` | the modification time |
| `permission as string` | `r` or `rw`; `""` when not reported |
| `starred as bool` | whether the account starred it |
| `isLocked as bool` | whether the file is locked |
| `modifier as string` | the last modifier's user id; `""` when not reported |

### `Revision`

| Field | Meaning |
|---|---|
| `commitId as string` | the commit; `revertFile` takes it |
| `fileId as string` | the file object id of this version |
| `path as string` | the path the file had |
| `size as int` | bytes |
| `ctime as int` | when it was committed |
| `creator as string` | the user id that made it |
| `creatorName as string` | that user's display name |
| `description as string` | the commit message |

### `Progress`

| Field | Meaning |
|---|---|
| `done as int` | items finished |
| `total as int` | items in the task |
| `canceled as bool` | whether it was canceled |
| `failed as bool` | whether it failed |
| `successful as bool` | whether it completed |

### `Share`

From `sharedWithMe`, `userName`, `groupId`, `groupName` and `isAdmin` are zero.

| Field | Meaning |
|---|---|
| `kind as string` | `user` or `group`; `public` from `sharedWithMe` |
| `user as string` | the user id (from `sharedWithMe`: the sharer); `""` for a group |
| `userName as string` | the user's display name |
| `groupId as int` | the group id; 0 for a user |
| `groupName as string` | the group's name |
| `permission as string` | one of `SHARE_PERMISSIONS` or `custom-<id>`; from `shares`, `admin` reads as `rw` with `isAdmin` |
| `isAdmin as bool` | whether the share grants admin rights |
| `repoId as string` | the library |
| `repoName as string` | the library's name; `""` when not reported |
| `path as string` | the shared folder, `/` for the whole library |

### `Starred`

| Field | Meaning |
|---|---|
| `repoId as string` | the library |
| `repoName as string` | the library's name |
| `path as string` | the path, `/` for the library |
| `name as string` | the name |
| `isDir as bool` | a folder or library |
| `mtime as int` | the modification time |
| `deleted as bool` | whether it no longer exists |

### `ShareLinkOptions`

| Field | Meaning |
|---|---|
| `password as string` | the password visitors give; `""` for none |
| `expireDays as int` | days until expiry; 0 for never |
| `noDownload as bool` | view only |
| `canEdit as bool` | visitors may edit (office files) |
| `canUpload as bool` | visitors may upload into a shared folder |

### `ShareLink`

| Field | Meaning |
|---|---|
| `token as string` | the link token |
| `link as string` | the URL to hand out |
| `repoId as string` | the library |
| `repoName as string` | the library's name |
| `path as string` | what it shares |
| `name as string` | the name of what it shares |
| `isDir as bool` | whether it shares a folder |
| `viewCount as int` | how often it was opened |
| `ctime as int` | when it was made |
| `expires as int` | when it expires; 0 for never |
| `isExpired as bool` | whether it has expired |
| `canEdit as bool` | visitors may edit |
| `canDownload as bool` | visitors may download |
| `canUpload as bool` | visitors may upload |

### `UploadLink`

| Field | Meaning |
|---|---|
| `token as string` | the link token |
| `link as string` | the URL to hand out |
| `repoId as string` | the library |
| `repoName as string` | the library's name |
| `path as string` | the folder |
| `viewCount as int` | how often it was opened |
| `ctime as int` | when it was made |
| `expires as int` | when it expires; 0 for never |
| `isExpired as bool` | whether it has expired |

### `TrashItem`

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `parentDir as string` | the folder it was deleted from |
| `path as string` | its full path |
| `isDir as bool` | whether it is a folder |
| `size as int` | bytes; 0 for a folder |
| `deleted as int` | when it was deleted |
| `commitId as string` | the commit that still holds it |
| `objId as string` | the object id; `""` for a folder |

### `TrashPage`

| Field | Meaning |
|---|---|
| `items as list of TrashItem` | the items, newest first |
| `more as bool` | whether the server has more to scan |
| `scanStat as string` | the cursor of the next page; `""` on the last |

### `ApiToken`

| Field | Meaning |
|---|---|
| `repoId as string` | the library it opens |
| `appName as string` | its name |
| `generatedBy as string` | the user id that made it |
| `permission as string` | `r` or `rw` |
| `token as string` | the token, for `withRepoToken` |

### `SearchOptions`

| Field | Meaning |
|---|---|
| `repoId as string` | only this library; `""` for all |
| `path as string` | only below this folder; needs `repoId` |
| `page as int` | the page, from 1; 0 for the first |
| `perPage as int` | results per page; 0 for the server's default |

### `SearchHit`

| Field | Meaning |
|---|---|
| `repoId as string` | the library |
| `repoName as string` | the library's name |
| `name as string` | the name |
| `path as string` | the path in the library |
| `isDir as bool` | whether it is a folder |
| `size as int` | bytes |
| `mtime as int` | the modification time |

## Connecting

| Function | Returns | Does |
|---|---|---|
| `seafile.client(baseUrl)` | `Client` | a client without credentials; refuses a URL with a query, fragment or user, a scheme other than `http`/`https`, no host or a bad port |
| `seafile.login(c, username, password, otp)` | `string` | an account token for `withToken`; `otp` the 2FA code or `""` |
| `seafile.withToken(c, token)` | `Client` | authenticate with an account token |
| `seafile.withRepoToken(c, repoId, token)` | `Client` | authenticate with a library API token (`via-repo-token` endpoints) |
| `seafile.withLegacyAuth(c)` | `Client` | send `Token <t>` (servers before 11.0) |
| `seafile.withFileServer(c, url)` | `Client` | accept transfer links on that origin too |
| `seafile.withPlainHttp(c)` | `Client` | allow credentials and transfer links over `http://` off loopback |
| `seafile.withCaCert(c, pem)` | `Client` | trust a PEM certificate (`bytes`); undoes `withInsecure` |
| `seafile.withInsecure(c)` | `Client` | accept any certificate |
| `seafile.withTimeout(c, ms)` | `Client` | set the idle timeout; refuses a negative `ms` |
| `seafile.withRetries(c, n)` | `Client` | retry API GETs answered 429 or 5xx, `n` 0 to `MAX_RETRIES` |
| `seafile.withReplyLimit(c, maxBytes)` | `Client` | cap every reply body but `get`'s; 0 for `REPLY_LIMIT`, negative for none |
| `seafile.call(c, method, path, body)` | `json.Value` | any endpoint under `/api2/` or `/api/v2.1/`; `method` GET/POST/PUT/PATCH/DELETE; `body` JSON text (sent as `application/json`) |
| `seafile.serverInfo(c)` | `ServerInfo` | version and features; no credentials needed |
| `seafile.account(c)` | `Account` | account; the user the token belongs to, with usage and quota |

## Libraries

| Function | Returns | Does |
|---|---|---|
| `seafile.libraries(c, type)` | `list of Library` | account; one of `LIBRARY_TYPES` or `""` for all |
| `seafile.library(c, id)` | `Library` | account; one library |
| `seafile.tokenLibrary(c)` | `Library` | library API token only: its library's id and name |
| `seafile.createLibrary(c, name, password)` | `Library` | account; `password` `""` for plain, else encrypted (sent to the server) |
| `seafile.renameLibrary(c, id, name)` | - | account |
| `seafile.removeLibrary(c, id)` | - | account; delete with everything in it |
| `seafile.decrypt(c, id, password)` | - | account; unlock an encrypted library on the server (sends the password) |

## Files and folders

| Function | Returns | Does |
|---|---|---|
| `seafile.listDir(c, repoId, path, type, recursive)` | `list of Entry` | entries of a folder; `type` `file`, `dir` or `""`; `recursive` for every depth |
| `seafile.fileDetail(c, repoId, path)` | `Entry` | one file |
| `seafile.dirDetail(c, repoId, path)` | `Entry` | account; one folder |
| `seafile.exists(c, repoId, path)` | `bool` | false on 404 `File/Folder ... not found`; a missing library throws |
| `seafile.mkdir(c, repoId, path, parents)` | `string` | make a folder; a taken name gets `x (1)`, the path made is returned; `parents` makes missing ones and keeps an existing folder |
| `seafile.get(c, repoId, path, maxBytes)` | `bytes` | download via the download link; 0 for `DOWNLOAD_LIMIT`, negative for none |
| `seafile.put(c, repoId, path, data, replace)` | `Entry` | upload via the upload link; without `replace` a taken name gets `x (1).txt`; account: drops a chunked upload's temp file at the path first (best effort; aborts another client's chunked upload of it); a name with `"` goes as one chunk, one with `\` throws |
| `seafile.update(c, repoId, path, data)` | `string` | account; overwrite an existing file, returns the new file id; drops a temp file as `put` |
| `seafile.putResumable(c, repoId, path, data, chunkSize, replace, resume)` | `Entry` | upload in chunks; `chunkSize` 0 for `CHUNK_SIZE`; `resume` continues at the server's offset (account token, same data only); otherwise starts at 0; account: drops a stale temp file, then chunks from 0, and restarts once after a first-chunk 400; library token: a first-chunk 400 sends the whole data through `put` in one POST |
| `seafile.rename(c, repoId, path, name)` | `string` | rename in place; returns the new path (a taken name gets `x (1)`) |
| `seafile.copy(c, repoId, path, toRepoId, toDir)` | - | copy a file or folder into a folder |
| `seafile.move(c, repoId, path, toRepoId, toDir)` | - | move a file or folder into a folder |
| `seafile.copyItems(c, repoId, dir, names, toRepoId, toDir)` | - | copy items of one folder, synchronously |
| `seafile.moveItems(c, repoId, dir, names, toRepoId, toDir)` | - | move items of one folder, synchronously |
| `seafile.copyAsync(c, repoId, dir, names, toRepoId, toDir)` | `string` | account; start a background copy, returns the task id |
| `seafile.moveAsync(c, repoId, dir, names, toRepoId, toDir)` | `string` | account; start a background move |
| `seafile.taskProgress(c, taskId)` | `Progress` | account; state of a background copy or move |
| `seafile.cancelTask(c, taskId)` | - | account; cancel it |
| `seafile.remove(c, repoId, path)` | - | move a file or folder to the trash; not `/` |
| `seafile.removeItems(c, repoId, dir, names)` | - | delete items of one folder; missing names are skipped |
| `seafile.lockFile(c, repoId, path)` | - | lock a file (Professional edition) |
| `seafile.unlockFile(c, repoId, path)` | - | unlock it (Professional edition) |

## History

| Function | Returns | Does |
|---|---|---|
| `seafile.fileHistory(c, repoId, path)` | `list of Revision` | account; versions of a file, newest first, past renames; refuses past `MAX_PAGES` |
| `seafile.revertFile(c, repoId, path, commitId)` | - | restore a file to a commit's version |
| `seafile.revertDir(c, repoId, path, commitId)` | - | restore a folder to a commit's state |

## Shares and stars

| Function | Returns | Does |
|---|---|---|
| `seafile.shares(c, repoId, path, kind)` | `list of Share` | account; users (`kind` `user`) or groups (`group`) a library (`/`) or folder is shared with |
| `seafile.share(c, repoId, path, kind, who, permission)` | - | account; share with a user id or group id; a reported failure throws |
| `seafile.changeShare(c, repoId, path, kind, who, permission)` | - | account; change a share's permission |
| `seafile.unshare(c, repoId, path, kind, who)` | - | account; end a share |
| `seafile.sharedFolders(c)` | `list of Share` | account; folders the account shares |
| `seafile.sharedWithMe(c)` | `list of Share` | account; libraries shared with the account; sharer and permission for user shares only |
| `seafile.starred(c)` | `list of Starred` | account; starred items |
| `seafile.star(c, repoId, path)` | - | account; star a library (`/`), folder or file |
| `seafile.unstar(c, repoId, path)` | - | account; unstar it |

## Links

| Function | Returns | Does |
|---|---|---|
| `seafile.createShareLink(c, repoId, path, opts)` | `ShareLink` | a download link; a library API token takes no password or expiry |
| `seafile.shareLinks(c)` | `list of ShareLink` | account; every share link |
| `seafile.shareLinksOf(c, repoId, path)` | `list of ShareLink` | account; links of a library (`path` `""`) or of one path |
| `seafile.deleteShareLink(c, token)` | - | account; delete a share link |
| `seafile.createUploadLink(c, repoId, path, password, expireDays)` | `UploadLink` | account; others upload into a folder through it |
| `seafile.uploadLinks(c)` | `list of UploadLink` | account; every upload link |
| `seafile.deleteUploadLink(c, token)` | - | account; delete an upload link |

## Trash

| Function | Returns | Does |
|---|---|---|
| `seafile.trash(c, repoId, path, scanStat)` | `TrashPage` | account; one page below a folder; `scanStat` `""` for the first |
| `seafile.trashAll(c, repoId, path)` | `list of TrashItem` | account; every page; stops at a repeated cursor, refuses past `MAX_PAGES` |
| `seafile.restore(c, repoId, items)` | - | account; put items back, one request per commit |
| `seafile.cleanTrash(c, repoId, keepDays)` | - | account; drop history older than `keepDays`; no undo |

## Library API tokens

| Function | Returns | Does |
|---|---|---|
| `seafile.createApiToken(c, repoId, appName, permission)` | `ApiToken` | account; a token for one library, `r` or `rw` |
| `seafile.apiTokens(c, repoId)` | `list of ApiToken` | account; the library's tokens |
| `seafile.setApiTokenPermission(c, repoId, appName, permission)` | `ApiToken` | account; change a token's permission |
| `seafile.deleteApiToken(c, repoId, appName)` | - | account; revoke a token |

## Search

| Function | Returns | Does |
|---|---|---|
| `seafile.search(c, query, opts)` | `list of SearchHit` | account; full-text search (Professional edition; Community Edition answers 403) |
| `seafile.searchNames(c, repoId, query)` | `list of Entry` | account; files and folders of one library whose name contains `query`; folders `dir` |
