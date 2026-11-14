# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * A client for the Web API of a self-hosted Seafile server (`/api2` and
 * `/api/v2.1`).
 *
 * Server and account info; libraries (list, create incl. encrypted, rename,
 * remove, decrypt); files and folders by library id and path (list, detail,
 * mkdir, download, upload, resumable upload, update, rename, copy, move,
 * remove, lock, history, revert); async batch copy and move; user and group
 * shares, libraries shared with the account; starred items; share and
 * upload links; the trash (list, restore, clean); library API tokens;
 * search. `call` reaches any other endpoint.
 *
 * A `Client` authenticates with an account token (`login`, `withToken`) or
 * a library API token (`withRepoToken`, the `via-repo-token` endpoints,
 * limited to one library). Every failure is a `SeafileError` (kind
 * "seafile", with the HTTP `status`), except a reached cap (a body over its
 * limit, too many pages): kind "limit".
 * Transfers take two steps: an upload or download link from the API, then
 * the `/seafhttp/...` URL, which carries its own token; no `Authorization`
 * goes there, and a link on another origin than the base URL is refused
 * unless `withFileServer` names it. Bodies are held in memory; `get` refuses
 * a file over `DOWNLOAD_LIMIT` (64 MiB) unless `maxBytes` says otherwise.
 * Credentials and transfer links go over plain `http://` only to a
 * loopback host or after `withPlainHttp`.
 *
 * @module seafile
 * @see https://seafile-api.readme.io/
 * @example
 *   def c as seafile.Client init seafile.client("https://cloud.example.com");
 *   $c = seafile.withToken($c, seafile.login($c, "me@example.com", $password, ""));
 *   for (def lib in seafile.libraries($c, "mine")) {
 *       io.printf("%s %s\n", $lib.id, $lib.name);
 *   }
 */
use convert;
use json;
use lists;
use maps;
use regex;
use strings;
use time;
import "http.j" as http;
import "multipart.j" as multipart;
import "uri.j" as uri;

/** The `kind` of every error the deck throws. */
export def const ERROR_KIND as string init "seafile";

/**
 * The largest file `get` accepts when `maxBytes` is 0: 64 MiB.
 */
export def const DOWNLOAD_LIMIT as int init 67108864;

/**
 * The largest reply body of every request but `get` when
 * `Client.replyLimit` is 0: 64 MiB.
 */
export def const REPLY_LIMIT as int init 67108864;

/** The most retries `withRetries` accepts. */
export def const MAX_RETRIES as int init 10;

/** The most pages `trashAll` and `fileHistory` follow before they refuse. */
export def const MAX_PAGES as int init 1000;

/** The chunk size of `putResumable` when `chunkSize` is 0: 8 MiB. */
export def const CHUNK_SIZE as int init 8388608;

/** The values the `type` argument of `libraries` takes besides "". */
export def const LIBRARY_TYPES as list of string init ["mine", "shared", "group", "org"];

/**
 * The permissions `share` and `changeShare` accept, besides `custom-<id>`
 * (a custom share permission). `preview`, `cloud-edit` and `invisible` need
 * the Professional edition.
 */
export def const SHARE_PERMISSIONS as list of string init [
    "r",
    "rw",
    "admin",
    "preview",
    "cloud-edit",
    "invisible"
];

/** The permissions of a library API token. */
export def const TOKEN_PERMISSIONS as list of string init ["r", "rw"];

/**
 * A connection to one Seafile server.
 *
 * @field url {string} `http[s]://host[:port][/path]`, without `/api2`
 * @field token {string} the account or library API token; "" for none
 * @field legacyAuth {bool} send `Token <t>` instead of `Bearer <t>` (servers
 *   before 11.0)
 * @field repoToken {bool} `token` is a library API token: requests go to the
 *   `via-repo-token` endpoints
 * @field repoId {string} the library a library API token belongs to; "" for
 *   unchecked
 * @field fileServer {string} a further origin transfer links may point at,
 *   `scheme://host:port`; "" for none
 * @field tls {http.TlsOptions} certificate checking
 * @field timeoutMs {int} the idle timeout of each request; 0 for 30 s, never
 *   negative
 * @field retries {int} retries of a GET answered 429 or 5xx, 0 to
 *   `MAX_RETRIES`
 * @field replyLimit {int} the largest reply of every request but `get`; 0
 *   for `REPLY_LIMIT`, negative for none
 * @field plainHttp {bool} send credentials and transfer tokens over
 *   `http://` to a host that is not loopback
 */
export def struct Client {
    url as string,
    token as string,
    legacyAuth as bool,
    repoToken as bool,
    repoId as string,
    fileServer as string,
    tls as http.TlsOptions,
    timeoutMs as int,
    retries as int,
    replyLimit as int,
    plainHttp as bool
};

/**
 * What the server says about itself.
 *
 * @field version {string} e.g. `13.0.29`
 * @field encryptedLibraryVersion {int} the version new encrypted libraries
 *   get
 * @field features {list of string} e.g. `seafile-basic`, `seafile-pro`
 */
export def struct ServerInfo {
    version as string,
    encryptedLibraryVersion as int,
    features as list of string
};

/**
 * An account.
 *
 * @field email {string} the user id, an e-mail address or `x@auth.local`
 * @field name {string} the display name
 * @field loginId {string} the login id; often ""
 * @field contactEmail {string} the contact address
 * @field institution {string} the institution
 * @field department {string} the department
 * @field isStaff {bool} whether the account is a system admin
 * @field usage {int} bytes used
 * @field total {int} the quota in bytes; -2 for unlimited
 */
export def struct Account {
    email as string,
    name as string,
    loginId as string,
    contactEmail as string,
    institution as string,
    department as string,
    isStaff as bool,
    usage as int,
    total as int
};

/**
 * A library (repository).
 *
 * @field id {string} the library id, a UUID
 * @field name {string} the name
 * @field type {string} `repo` (own), `srepo` (shared with the account),
 *   `grepo` (group); "" when the reply does not say
 * @field owner {string} the owner's user id
 * @field size {int} bytes
 * @field mtime {int} the last change, seconds since the epoch
 * @field encrypted {bool} whether it is encrypted
 * @field permission {string} the account's permission, `r` or `rw`
 */
export def struct Library {
    id as string,
    name as string,
    type as string,
    owner as string,
    size as int,
    mtime as int,
    encrypted as bool,
    permission as string
};

/**
 * A file or folder.
 *
 * @field name {string} the name
 * @field path {string} the path in its library, e.g. `/docs/a.txt`
 * @field type {string} `file` or `dir`
 * @field id {string} the object id; all zeros for an empty file or folder
 * @field size {int} bytes; 0 for a folder
 * @field mtime {int} the modification time, seconds since the epoch
 * @field permission {string} `r` or `rw`; "" when the reply does not say
 * @field starred {bool} whether the account starred it
 * @field isLocked {bool} whether the file is locked
 * @field modifier {string} the user id of the last modifier; "" when the
 *   reply does not say
 */
export def struct Entry {
    name as string,
    path as string,
    type as string,
    id as string,
    size as int,
    mtime as int,
    permission as string,
    starred as bool,
    isLocked as bool,
    modifier as string
};

/**
 * A version of a file, from `fileHistory`.
 *
 * @field commitId {string} the commit; `revertFile` takes it
 * @field fileId {string} the file object id of this version
 * @field path {string} the path the file had
 * @field size {int} bytes
 * @field ctime {int} when it was committed, seconds since the epoch
 * @field creator {string} the user id that made it
 * @field creatorName {string} that user's display name
 * @field description {string} the commit message
 */
export def struct Revision {
    commitId as string,
    fileId as string,
    path as string,
    size as int,
    ctime as int,
    creator as string,
    creatorName as string,
    description as string
};

/**
 * The state of an async copy or move.
 *
 * @field done {int} items finished
 * @field total {int} items in the task
 * @field canceled {bool} whether it was canceled
 * @field failed {bool} whether it failed
 * @field successful {bool} whether it completed
 */
export def struct Progress {
    done as int,
    total as int,
    canceled as bool,
    failed as bool,
    successful as bool
};

/**
 * A share of a library or folder with a user or group. From
 * `sharedWithMe`, `userName`, `groupId`, `groupName` and `isAdmin` are
 * zero (the server does not send them).
 *
 * @field kind {string} `user` or `group`; `public` from `sharedWithMe`
 * @field user {string} the user id (from `sharedWithMe`: the sharer); ""
 *   for a group
 * @field userName {string} the user's display name
 * @field groupId {int} the group id; 0 for a user
 * @field groupName {string} the group's name
 * @field permission {string} one of `SHARE_PERMISSIONS` or `custom-<id>`;
 *   `shares` reports `admin` as `rw` with `isAdmin`
 * @field isAdmin {bool} whether the share grants admin rights
 * @field repoId {string} the library
 * @field repoName {string} the library's name; "" when the reply does not
 *   say
 * @field path {string} the shared folder, `/` for the whole library
 */
export def struct Share {
    kind as string,
    user as string,
    userName as string,
    groupId as int,
    groupName as string,
    permission as string,
    isAdmin as bool,
    repoId as string,
    repoName as string,
    path as string
};

/**
 * A starred library, folder or file.
 *
 * @field repoId {string} the library
 * @field repoName {string} the library's name
 * @field path {string} the path, `/` for the library itself
 * @field name {string} the name
 * @field isDir {bool} whether it is a folder or library
 * @field mtime {int} the modification time, seconds since the epoch
 * @field deleted {bool} whether it no longer exists
 */
export def struct Starred {
    repoId as string,
    repoName as string,
    path as string,
    name as string,
    isDir as bool,
    mtime as int,
    deleted as bool
};

/**
 * Options of `createShareLink`. The zero value: no password, no expiry,
 * visitors may view and download.
 *
 * @field password {string} the password visitors must give; "" for none
 * @field expireDays {int} days until the link expires; 0 for never
 * @field noDownload {bool} visitors may view but not download
 * @field canEdit {bool} visitors may edit (office files)
 * @field canUpload {bool} visitors may upload into a shared folder
 */
export def struct ShareLinkOptions {
    password as string,
    expireDays as int,
    noDownload as bool,
    canEdit as bool,
    canUpload as bool
};

/**
 * A download share link.
 *
 * @field token {string} the link token; `deleteShareLink` takes it
 * @field link {string} the URL to hand out
 * @field repoId {string} the library
 * @field repoName {string} the library's name
 * @field path {string} what it shares
 * @field name {string} the name of what it shares
 * @field isDir {bool} whether it shares a folder
 * @field viewCount {int} how often it was opened
 * @field ctime {int} when it was made, seconds since the epoch
 * @field expires {int} when it expires, seconds since the epoch; 0 for never
 * @field isExpired {bool} whether it has expired
 * @field canEdit {bool} visitors may edit
 * @field canDownload {bool} visitors may download
 * @field canUpload {bool} visitors may upload
 */
export def struct ShareLink {
    token as string,
    link as string,
    repoId as string,
    repoName as string,
    path as string,
    name as string,
    isDir as bool,
    viewCount as int,
    ctime as int,
    expires as int,
    isExpired as bool,
    canEdit as bool,
    canDownload as bool,
    canUpload as bool
};

/**
 * An upload link: others upload into a folder through it.
 *
 * @field token {string} the link token; `deleteUploadLink` takes it
 * @field link {string} the URL to hand out
 * @field repoId {string} the library
 * @field repoName {string} the library's name
 * @field path {string} the folder
 * @field viewCount {int} how often it was opened
 * @field ctime {int} when it was made, seconds since the epoch
 * @field expires {int} when it expires, seconds since the epoch; 0 for never
 * @field isExpired {bool} whether it has expired
 */
export def struct UploadLink {
    token as string,
    link as string,
    repoId as string,
    repoName as string,
    path as string,
    viewCount as int,
    ctime as int,
    expires as int,
    isExpired as bool
};

/**
 * A file or folder in a library's trash.
 *
 * @field name {string} the name
 * @field parentDir {string} the folder it was deleted from
 * @field path {string} its full path when it was deleted
 * @field isDir {bool} whether it is a folder
 * @field size {int} bytes; 0 for a folder
 * @field deleted {int} when it was deleted, seconds since the epoch
 * @field commitId {string} the commit that still holds it; `restore` uses it
 * @field objId {string} the object id; "" for a folder
 */
export def struct TrashItem {
    name as string,
    parentDir as string,
    path as string,
    isDir as bool,
    size as int,
    deleted as int,
    commitId as string,
    objId as string
};

/**
 * One page of a library's trash.
 *
 * @field items {list of TrashItem} the items, newest first
 * @field more {bool} whether the server has more to scan
 * @field scanStat {string} the cursor of the next page; "" on the last
 */
export def struct TrashPage {
    items as list of TrashItem,
    more as bool,
    scanStat as string
};

/**
 * A library API token.
 *
 * @field repoId {string} the library it opens
 * @field appName {string} the name it was created under
 * @field generatedBy {string} the user id that created it
 * @field permission {string} `r` or `rw`
 * @field token {string} the token; `withRepoToken` takes it
 */
export def struct ApiToken {
    repoId as string,
    appName as string,
    generatedBy as string,
    permission as string,
    token as string
};

/**
 * Filters of a `search`. The zero value searches all libraries, first page,
 * the server's page size.
 *
 * @field repoId {string} only this library; "" for all the account reaches
 * @field path {string} only below this folder; needs `repoId`
 * @field page {int} the page, from 1; 0 for the first
 * @field perPage {int} results per page; 0 for the server's default
 */
export def struct SearchOptions {
    repoId as string,
    path as string,
    page as int,
    perPage as int
};

/**
 * A search result.
 *
 * @field repoId {string} the library
 * @field repoName {string} the library's name
 * @field name {string} the name
 * @field path {string} the path in the library
 * @field isDir {bool} whether it is a folder
 * @field size {int} bytes
 * @field mtime {int} the modification time, seconds since the epoch
 */
export def struct SearchHit {
    repoId as string,
    repoName as string,
    name as string,
    path as string,
    isDir as bool,
    size as int,
    mtime as int
};

# The two API roots under the base URL.
def const API2 as string init "/api2";
def const V21 as string init "/api/v2.1";

# The endpoints a library API token reaches.
def const VIA as string init "/api/v2.1/via-repo-token";

# A library id: the UUID the server's routes accept.
def const REPO_ID_PATTERN as string init '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$';

# A share or upload link token, as the routes accept it.
def const LINK_TOKEN_PATTERN as string init '^[a-f0-9]+$';

# A commit id.
def const COMMIT_PATTERN as string init '^[0-9a-f]{40}$';

# A commit id no library has: the `head` that makes the fileserver refuse
# a completed chunk after it has dropped the temp file.
def const NO_COMMIT as string init "0000000000000000000000000000000000000000";

# The largest temp file offset taken from the server (2^53, far above
# Seafile's file size limit); more is a broken reply.
def const MAX_OFFSET as int init 9007199254740992;

# How much of a string an error message repeats.
def const SHOWN as int init 60;

# How much of the server's reason for a refusal an error message repeats.
def const REASON as int init 200;

# The idle timeout a `timeoutMs` of 0 stands for, as `http.send` has it.
def const DEFAULT_TIMEOUT_MS as int init 30000;

/**
 * A failed Seafile request. Every error of kind `"seafile"` is one, so its
 * fields are safe to read once the kind matches.
 *
 * @field kind {string} always `"seafile"` (`ERROR_KIND`)
 * @field message {string} `seafile: <request>: HTTP <status>: <reason>`, or what went wrong
 * @field status {int} the HTTP status the server answered (403, 404, 440 a locked file, 443 over quota, ...); 0 when the failure is not a refused request
 */
export def struct SeafileError {
    kind as string,
    message as string,
    status as int
};

func fail(message as string) {
    throw SeafileError{kind: ERROR_KIND, message: "seafile: " + $message, status: 0};
}

/**
 * Throw the SeafileError of a refused request.
 *
 * @param what {string} the request, for the message
 * @param status {int} the HTTP status
 * @param statusText {string} the reason phrase
 * @param body {string} the body
 * @param note {string} text to append to the message, "" for none
 */
func failHttp(what as string, status as int, statusText as string, body as string, note as string) {
    throw SeafileError{
        kind: ERROR_KIND,
        message: "seafile: " + $what + ": " + failureText($status, $statusText, $body) + $note,
        status: $status
    };
}

/**
 * A string fit for an error message: cut to `most` characters, with
 * anything but printable ASCII as `?`, so a message stays one line and
 * carries no terminal escape into a log.
 *
 * @param text {string} a caller's or the server's string
 * @param most {int} the characters kept
 * @return {string} the text
 */
func plain(text as string, most as int) {
    def cut as string init $text;
    def more as string init "";
    if (len($text) > $most) {
        $cut = strings.substring($text, 0, $most);
        $more = "...";
    }
    return regex.replace("[^ -~]", $cut, "?") + $more;
}

/**
 * A string as an error message quotes it: `plain`, cut to `SHOWN`.
 *
 * @param text {string} a caller's or the server's string
 * @return {string} the text in double quotes
 */
func shown(text as string) {
    return "\"" + plain($text, SHOWN) + "\"";
}

/**
 * A path without its trailing slashes.
 *
 * @param path {string} a URL or library path
 * @return {string} the path
 */
func trimSlashes(path as string) {
    def out as string init $path;
    while (strings.endsWith($out, "/")) {
        $out = strings.substring($out, 0, len($out) - 1);
    }
    return $out;
}

/**
 * The parts of an absolute URL, checked: scheme `http`/`https`
 * (lower-cased), a host of letters, digits, `.`, `-`, `_` or a bracketed
 * IPv6 literal, a port 1-65535, no user, no control characters or spaces.
 *
 * @param url {string} the URL
 * @param what {string} what it is, for the error message
 * @return {uri.Uri} the parts, scheme and host lower-cased
 */
func urlParts(url as string, what as string) {
    if (regex.matches("[\\s\\x00-\\x1f\\x7f]", $url)) {
        fail("a " + $what + " holds no spaces or control characters, got " + shown($url));
    }
    if (not strings.contains($url, "://")) {
        fail("a " + $what + " is http:// or https://, got " + shown($url));
    }
    def u as uri.Uri init uri.parse($url);
    $u.scheme = strings.lower($u.scheme);
    $u.host = strings.lower($u.host);
    if ($u.scheme != "http" and $u.scheme != "https") {
        fail("a " + $what + " is http:// or https://, got " + shown($url));
    }
    def rest as string init strings.substring($url, strings.indexOf($url, "://") + 3, len($url));
    def cut as int init len($rest);
    for (def stop in ["/", "?", "#"]) {
        if (strings.contains($rest, $stop) and strings.indexOf($rest, $stop) < $cut) {
            $cut = strings.indexOf($rest, $stop);
        }
    }
    $rest = strings.substring($rest, 0, $cut);
    if (strings.contains($rest, "@")) {
        fail("a " + $what + " holds no user or password, got " + shown($url));
    }
    if (not regex.matches('^([a-z0-9._-]+|\[[0-9a-f:.]+\])$', $u.host)) {
        fail("a " + $what + " names a host, got " + shown($url));
    }
    if ($u.port != "" or strings.endsWith($rest, ":")) {
        if (not regex.matches('^[0-9]{1,5}$', $u.port) or convert.toInt($u.port) == 0 or
            convert.toInt($u.port) > 65535) {
            fail("a " + $what + " port is 1 to 65535, got " + shown($url));
        }
    }
    return $u;
}

/**
 * The origin of a checked URL: scheme, host and port, the default port
 * written out.
 *
 * @param u {uri.Uri} the parts from `urlParts`
 * @return {string} `scheme://host:port`
 */
func originOf(u as uri.Uri) {
    def port as string init $u.port;
    if ($port == "") {
        $port = "443";
        if ($u.scheme == "http") {
            $port = "80";
        }
    }
    return $u.scheme + "://" + $u.host + ":" + convert.toString(convert.toInt($port));
}

/**
 * The base URL for a host name or URL. A bare host gets `https://`; the
 * scheme and host are lower-cased; trailing slashes and a trailing `/api2`
 * or `/api/v2.1` are dropped.
 *
 * @param address {string} `cloud.example.com` or a full URL
 * @return {string} `http[s]://host[:port][/path]`
 */
func normalUrl(address as string) {
    def url as string init strings.trim($address);
    if ($url == "") {
        fail("the base URL is empty");
    }
    if (regex.matches("[\\s\\x00-\\x1f\\x7f]", $url)) {
        fail("a base URL holds no spaces or control characters, got " + shown($url));
    }
    if (not strings.contains($url, "://")) {
        $url = "https://" + $url;
    }
    if (strings.contains($url, "?") or strings.contains($url, "#")) {
        fail("a base URL has no query or fragment, got " + shown($url));
    }
    def u as uri.Uri init urlParts($url, "base URL");
    def port as string init "";
    if ($u.port != "") {
        $port = ":" + $u.port;
    }
    def path as string init trimSlashes($u.path);
    if (strings.endsWith($path, V21)) {
        $path = trimSlashes(strings.substring($path, 0, len($path) - len(V21)));
    } elseif (strings.endsWith($path, API2)) {
        $path = trimSlashes(strings.substring($path, 0, len($path) - len(API2)));
    }
    return $u.scheme + "://" + $u.host + $port + $path;
}

/**
 * A client for a Seafile server, without credentials.
 *
 * @param baseUrl {string} the server's URL (`SERVICE_URL`), or a bare host
 *   (gets `https://`); a trailing `/api2` or `/api/v2.1` is dropped
 * @return {Client} the client; full certificate checking
 * @throws {Error} kind `"seafile"` when the URL is empty, holds spaces or
 *   control characters, a query, a fragment or a user, has a scheme other
 *   than `http`/`https`, no host or a port outside 1-65535
 * @example
 *   def c as seafile.Client init seafile.client("https://cloud.example.com");
 */
export func client(baseUrl as string) {
    def c as Client;
    $c.url = normalUrl($baseUrl);
    return $c;
}

/**
 * A token, checked: not empty, no spaces or control characters.
 *
 * @param token {string} the token
 * @return {string} the token
 */
func checkToken(token as string) {
    if ($token == "" or regex.matches("[\\s\\x00-\\x1f\\x7f]", $token)) {
        fail("a token is not empty and holds no spaces or control characters");
    }
    return $token;
}

/**
 * Authenticate with an account token, from `login` or made in the web UI.
 * It acts as the account on every endpoint; it stays valid until it is
 * revoked (Settings > Devices, or `DELETE /api2/auth-token/`). Each request
 * refuses to send it over `http://` to a host that is not loopback, unless
 * `withPlainHttp` was set. Undoes `withRepoToken`.
 *
 * @param c {Client} the client
 * @param token {string} the token
 * @return {Client} the changed copy
 * @throws {Error} kind `"seafile"` when the token is empty or holds spaces
 *   or control characters
 */
export func withToken(c as Client, token as string) {
    $c.token = checkToken($token);
    $c.repoToken = false;
    $c.repoId = "";
    return $c;
}

/**
 * Authenticate with a library API token (`createApiToken`, or the library's
 * "API Token" dialog). Requests then go to the `/api/v2.1/via-repo-token/`
 * endpoints and reach that one library only: `listDir`, `fileDetail`,
 * `exists`, `mkdir`, `get`, `put`, `putResumable` (without resume),
 * `rename`, `copy`, `move`, `copyItems`, `moveItems`, `remove`,
 * `removeItems`, `lockFile`, `unlockFile`, `revertFile`, `revertDir`,
 * `createShareLink` and `tokenLibrary`; `serverInfo` and `call` send the
 * token as well. Every other verb throws before it sends anything.
 *
 * @param c {Client} the client
 * @param repoId {string} the library the token belongs to; verbs then
 *   refuse another id. "" accepts any id. The id is never sent: the token
 *   decides the library
 * @param token {string} the token
 * @return {Client} the changed copy
 * @throws {Error} kind `"seafile"` on a bad token or library id
 */
export func withRepoToken(c as Client, repoId as string, token as string) {
    if ($repoId != "") {
        checkRepoId($repoId);
    }
    $c.token = checkToken($token);
    $c.repoToken = true;
    $c.repoId = $repoId;
    return $c;
}

/**
 * Send `Authorization: Token <t>` instead of `Bearer <t>`, for servers
 * before 11.0. Servers from 11.0 accept both.
 *
 * @param c {Client} the client
 * @return {Client} the changed copy
 */
export func withLegacyAuth(c as Client) {
    $c.legacyAuth = true;
    return $c;
}

/**
 * Accept transfer links (`/seafhttp/...`) on another origin than the base
 * URL: a server whose `FILE_SERVER_ROOT` names its own host or port. Links
 * on any other origin, and links that downgrade the base URL's `https` to
 * `http`, are refused; this origin is accepted whatever its scheme.
 *
 * @param c {Client} the client
 * @param url {string} the file server's URL, e.g.
 *   `https://files.example.com:8082`; only its origin counts
 * @return {Client} the changed copy
 * @throws {Error} kind `"seafile"` on a URL `client` would refuse
 */
export func withFileServer(c as Client, url as string) {
    $c.fileServer = originOf(urlParts(normalUrl($url), "file server URL"));
    return $c;
}

/**
 * Trust a certificate (PEM) in addition to the system's, for a server with
 * a private CA or a self-signed certificate. Undoes `withInsecure`.
 *
 * @param c {Client} the client
 * @param pem {bytes} the certificate
 * @return {Client} the changed copy
 */
export func withCaCert(c as Client, pem as bytes) {
    $c.tls.caCert = $pem;
    $c.tls.skipVerify = false;
    return $c;
}

/**
 * Accept any certificate. The connection is still encrypted but no longer
 * authenticated; prefer `withCaCert`.
 *
 * @param c {Client} the client
 * @return {Client} the changed copy
 */
export func withInsecure(c as Client) {
    $c.tls.skipVerify = true;
    return $c;
}

/**
 * Allow credentials, `login`'s password and transfer links over plain
 * `http://` to a host that is not loopback (127.0.0.0/8, `::1`,
 * `localhost`). Without it, such a request throws before it connects.
 *
 * @param c {Client} the client
 * @return {Client} the changed copy
 */
export func withPlainHttp(c as Client) {
    $c.plainHttp = true;
    return $c;
}

/**
 * Set the idle timeout of each request.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds; 0 for the default, 30 s
 * @return {Client} the changed copy
 * @throws {Error} kind `"seafile"` when `ms` is negative
 */
export func withTimeout(c as Client, ms as int) {
    if ($ms < 0) {
        fail("a timeout is 0 or more ms, got " + convert.toString($ms));
    }
    $c.timeoutMs = $ms;
    return $c;
}

/**
 * Set the largest reply of every request but `get` (which takes its own
 * `maxBytes`). A larger reply body throws. A recursive `listDir` of a
 * large library is the reply most likely to reach it.
 *
 * @param c {Client} the client
 * @param maxBytes {int} the cap; 0 for `REPLY_LIMIT`, negative for none
 * @return {Client} the changed copy
 */
export func withReplyLimit(c as Client, maxBytes as int) {
    $c.replyLimit = $maxBytes;
    return $c;
}

/**
 * Retry an API GET answered 429 or 5xx. The first retry waits 500 ms, each
 * further one twice as long, longer for a `Retry-After` in seconds, at most
 * 30 s. Writes are never retried (they need not be idempotent), nor are
 * transfers.
 *
 * @param c {Client} the client
 * @param n {int} retries, 0 for none, at most `MAX_RETRIES`
 * @return {Client} the changed copy
 * @throws {Error} kind `"seafile"` when `n` is negative or over
 *   `MAX_RETRIES`
 */
export func withRetries(c as Client, n as int) {
    if ($n < 0 or $n > MAX_RETRIES) {
        fail("retries are 0 to " + convert.toString(MAX_RETRIES) + ", got " + convert.toString($n));
    }
    $c.retries = $n;
    return $c;
}

/**
 * A library id, checked.
 *
 * @param id {string} the id
 * @return {string} the id
 */
func checkRepoId(id as string) {
    if (not regex.matches(REPO_ID_PATTERN, $id)) {
        fail("a library id is a lower-case UUID, got " + shown($id));
    }
    return $id;
}

/**
 * A share or upload link token, checked.
 *
 * @param token {string} the token
 * @return {string} the token
 */
func checkLinkToken(token as string) {
    if (not regex.matches(LINK_TOKEN_PATTERN, $token)) {
        fail("a link token is lower-case hex, got " + shown($token));
    }
    return $token;
}

/**
 * A commit id, checked.
 *
 * @param id {string} the id
 * @return {string} the id
 */
func checkCommit(id as string) {
    if (not regex.matches(COMMIT_PATTERN, $id)) {
        fail("a commit id is 40 hex digits, got " + shown($id));
    }
    return $id;
}

/**
 * A share permission, checked: one of `SHARE_PERMISSIONS` or `custom-<id>`.
 *
 * @param permission {string} the permission
 * @return {string} the permission
 */
func checkSharePermission(permission as string) {
    if (lists.contains(SHARE_PERMISSIONS, $permission) or
        regex.matches('^custom-[0-9]{1,18}$', $permission)) {
        return $permission;
    }
    def choices as string init strings.join(SHARE_PERMISSIONS, ", ");
    fail("a permission is one of " + $choices + " or custom-<id>, got " + shown($permission));
}

/**
 * A value that must be one of a list, checked.
 *
 * @param value {string} the value
 * @param allowed {list of string} the values allowed
 * @param what {string} what it is, for the error message
 * @return {string} the value
 */
func checkOneOf(value as string, allowed as list of string, what as string) {
    if (not lists.contains($allowed, $value)) {
        def choices as string init strings.join($allowed, ", ");
        fail("a " + $what + " is one of " + $choices + ", got " + shown($value));
    }
    return $value;
}

/**
 * A path in a library, checked: absolute, no empty, `.` or `..` segments,
 * no control characters, no trailing `/` but on the root.
 *
 * @param path {string} e.g. `/docs/a.txt` or `/`
 * @return {string} the path
 */
func checkPath(path as string) {
    if (not strings.startsWith($path, "/") or regex.matches("[\\x00-\\x1f\\x7f]", $path)) {
        fail("a path starts with / and holds no control characters, got " + shown($path));
    }
    if ($path == "/") {
        return $path;
    }
    for (def segment in strings.split(strings.substring($path, 1, len($path)), "/")) {
        if ($segment == "" or $segment == "." or $segment == "..") {
            fail("a path has no empty, . or .. segments, got " + shown($path));
        }
    }
    return $path;
}

/**
 * A path that names something below the root, checked.
 *
 * @param path {string} the path
 * @param what {string} what is refused on the root, for the error message
 * @return {string} the path
 */
func checkItem(path as string, what as string) {
    if (checkPath($path) == "/") {
        fail("the root cannot be " + $what);
    }
    return $path;
}

/**
 * A file or folder name, checked: not empty, not `.` or `..`, no `/` or
 * control characters.
 *
 * @param name {string} the name
 * @return {string} the name
 */
func checkName(name as string) {
    if ($name == "" or $name == "." or $name == ".." or strings.contains($name, "/") or
        regex.matches("[\\x00-\\x1f\\x7f]", $name)) {
        fail("a name is not empty, . or .. and holds no / or control characters, got " +
            shown($name));
    }
    return $name;
}

/**
 * Names of a batch, checked: at least one, each `checkName`.
 *
 * @param names {list of string} the names
 * @return {list of string} the names
 */
func checkNames(names as list of string) {
    if (len($names) == 0) {
        fail("a batch names at least one item");
    }
    for (def n in $names) {
        checkName($n);
    }
    return $names;
}

/**
 * A text value that goes into a form or header, checked: not empty, no
 * control characters.
 *
 * @param text {string} the value
 * @param what {string} what it is, for the error message
 * @return {string} the value
 */
func checkText(text as string, what as string) {
    if ($text == "" or regex.matches("[\\x00-\\x1f\\x7f]", $text)) {
        fail("a " + $what + " is not empty and holds no control characters");
    }
    return $text;
}

/**
 * The folder a path is in.
 *
 * @param path {string} a checked path other than `/`
 * @return {string} the parent, `/` at the top
 */
func parentOf(path as string) {
    def at as int init strings.lastIndexOf($path, "/");
    if ($at <= 0) {
        return "/";
    }
    return strings.substring($path, 0, $at);
}

/**
 * The last segment of a path.
 *
 * @param path {string} a checked path other than `/`
 * @return {string} the name
 */
func nameOf(path as string) {
    return strings.substring($path, strings.lastIndexOf($path, "/") + 1, len($path));
}

/**
 * A path below a folder.
 *
 * @param dir {string} the folder, with or without a trailing `/`
 * @param name {string} a name; "" for the folder itself
 * @return {string} the joined path
 */
func joined(dir as string, name as string) {
    def base as string init $dir;
    if (strings.endsWith($base, "/")) {
        $base = trimSlashes($base);
    }
    if ($name == "") {
        if ($base == "") {
            return "/";
        }
        return $base;
    }
    return $base + "/" + $name;
}

/**
 * Whether a host is loopback: `localhost`, `[::1]` or an address in
 * 127.0.0.0/8.
 *
 * @param host {string} a lower-cased host
 * @return {bool} whether it is loopback
 */
func isLoopbackHost(host as string) {
    return $host == "localhost" or $host == "[::1]" or
        regex.matches('^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$', $host);
}

/**
 * Refuse a secret over `http://` to a host that is not loopback, unless
 * `plainHttp` is set. Decides on the parsed, lower-cased scheme and host.
 *
 * @param c {Client} the client
 * @param url {string} where the request goes
 * @param what {string} what would cross, for the error message
 */
func guardPlain(c as Client, url as string, what as string) {
    def u as uri.Uri init urlParts($url, "URL");
    if ($u.scheme == "http" and not $c.plainHttp and not isLoopbackHost($u.host)) {
        fail($what + " go over http:// only to a loopback host; use https:// or " +
            "withPlainHttp, got " + shown($url));
    }
}

/**
 * The headers of every API request. Refuses credentials over `http://` to
 * a host that is not loopback unless `plainHttp` is set.
 *
 * @param c {Client} the client
 * @return {map of string to string} the headers
 */
func baseHeaders(c as Client) {
    def headers as map of string to string init {"Accept": "application/json"};
    if ($c.token != "") {
        guardPlain($c, $c.url, "credentials");
        if ($c.legacyAuth) {
            $headers["Authorization"] = "Token " + $c.token;
        } else {
            $headers["Authorization"] = "Bearer " + $c.token;
        }
    }
    return $headers;
}

/**
 * The reply cap `http` takes.
 *
 * @param c {Client} the client
 * @return {int} bytes; negative for none
 */
func replyCap(c as Client) {
    if ($c.replyLimit == 0) {
        return REPLY_LIMIT;
    }
    return $c.replyLimit;
}

/**
 * The idle timeout for the `http` calls that take it directly, where 0
 * would mean no timeout at all.
 *
 * @param c {Client} the client
 * @return {int} milliseconds
 */
func idleMs(c as Client) {
    if ($c.timeoutMs == 0) {
        return DEFAULT_TIMEOUT_MS;
    }
    return $c.timeoutMs;
}

/**
 * Send a request to the API and return the response, whatever its status.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method, upper case
 * @param route {string} the path under the base URL, `/api2/...` or
 *   `/api/v2.1/...`, query included
 * @param body {string} the body; "" for none
 * @param contentType {string} the body's type; "" for none
 * @return {http.Response} the response
 */
func sendRaw(
    c as Client,
    method as string,
    route as string,
    body as string,
    contentType as string) {
    def headers as map of string to string init baseHeaders($c);
    if ($contentType != "") {
        $headers["Content-Type"] = $contentType;
    }
    def o as http.Options;
    $o.tls = $c.tls;
    $o.timeoutMs = $c.timeoutMs;
    $o.maxBytes = replyCap($c);
    if ($method == "GET") {
        $o.maxRetries = $c.retries;
        $o.backoffMs = 500;
    }
    def r as http.Response;
    try {
        $r = http.send($method, $c.url + $route, $headers, $body, $o);
    } catch (e) {
        # a body over its limit stays a reached cap
        if ($e.kind == "limit") {
            throw Error{
                kind: "limit",
                message: "seafile: " + $method + " " + $route + ": " + $e.message
            };
        }
        fail($method + " " + $route + ": " + $e.message);
    }
    return $r;
}

/**
 * Whether a status is 2xx.
 *
 * @param status {int} the status
 * @return {bool} whether it is a success
 */
func isOk(status as int) {
    return $status >= 200 and $status < 300;
}

/**
 * Explain a refused request: the server's `error_msg`, `detail`, `error`,
 * the first of `non_field_errors`, or a JSON string body, cut to `REASON`
 * characters of printable ASCII; else the reason phrase.
 *
 * @param status {int} the HTTP status
 * @param statusText {string} the reason phrase
 * @param body {string} the body
 * @return {string} `HTTP <status>: <reason>`
 */
func failureText(status as int, statusText as string, body as string) {
    def text as string init "HTTP " + convert.toString($status);
    def reason as string init strings.trim($statusText);
    def said as string init serverReason($body);
    if ($said != "") {
        $reason = $said;
    }
    if ($reason != "") {
        $text = $text + ": " + plain($reason, REASON);
    }
    return $text;
}

/**
 * The reason a refusal body gives, as `failureText` reads it. The
 * fileserver ends its `error` with a raw newline, which is not JSON:
 * control characters become spaces before decoding.
 *
 * @param body {string} the body
 * @return {string} the reason, trimmed; "" when it gives none
 */
func serverReason(body as string) {
    def doc as json.Value init json.decode("null");
    try {
        $doc = json.decode(regex.replace("[\\x00-\\x1f]", $body, " "));
    } catch (e) {
        return "";
    }
    def kind as string init json.typeOf($doc);
    if ($kind == "string") {
        return strings.trim(json.asString($doc));
    }
    if ($kind != "map") {
        return "";
    }
    for (def key in ["/error_msg", "/detail", "/error", "/non_field_errors/0", "/error_msg/0"]) {
        def said as string init strings.trim(field($doc, $key));
        if ($said != "") {
            return $said;
        }
    }
    return "";
}

/**
 * Send a request to the API and return the response, a non-2xx refused.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method, upper case
 * @param route {string} the path under the base URL
 * @param body {string} the body; "" for none
 * @param contentType {string} the body's type; "" for none
 * @return {http.Response} the response
 */
func exchange(
    c as Client,
    method as string,
    route as string,
    body as string,
    contentType as string) {
    def r as http.Response init sendRaw($c, $method, $route, $body, $contentType);
    if (not isOk($r.status)) {
        failHttp($method + " " + $route, $r.status, $r.statusText, $r.body, "");
    }
    return $r;
}

/**
 * Decode a reply body.
 *
 * @param body {string} the body
 * @param what {string} the request, for the error message
 * @return {json.Value} the document; JSON `null` for an empty body
 */
func decoded(body as string, what as string) {
    if (strings.trim($body) == "") {
        return json.decode("null");
    }
    try {
        return json.decode($body);
    } catch (e) {
        fail($what + ": the reply is not JSON");
    }
    return json.decode("null");
}

/**
 * A request with a JSON body (or none), its reply decoded.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method, upper case
 * @param route {string} the path under the base URL, query included
 * @param body {string} JSON; "" for none
 * @return {json.Value} the reply; JSON `null` when it is empty
 */
func api(c as Client, method as string, route as string, body as string) {
    def kind as string init "";
    if ($body != "") {
        $kind = "application/json";
    }
    def r as http.Response init exchange($c, $method, $route, $body, $kind);
    return decoded($r.body, $method + " " + $route);
}

/**
 * A request with a form body, its reply decoded.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method, upper case
 * @param route {string} the path under the base URL, query included
 * @param form {string} the `application/x-www-form-urlencoded` body
 * @return {json.Value} the reply; JSON `null` when it is empty
 */
func apiForm(c as Client, method as string, route as string, form as string) {
    def r as http.Response init exchange(
        $c,
        $method,
        $route,
        $form,
        "application/x-www-form-urlencoded");
    return decoded($r.body, $method + " " + $route);
}

/**
 * Refuse an API route that would not address what it says.
 *
 * @param path {string} the path under the base URL, query string allowed
 */
func ensureRoute(path as string) {
    if (not strings.startsWith($path, API2 + "/") and not strings.startsWith($path, V21 + "/")) {
        fail("an API path starts with /api2/ or /api/v2.1/, got " + shown($path));
    }
    def route as string init $path;
    if (strings.contains($route, "?")) {
        $route = strings.substring($route, 0, strings.indexOf($route, "?"));
    }
    if (strings.contains($route, "//") or strings.contains($path, "#") or
        regex.matches("[\\x00-\\x20\\x7f]", $path)) {
        fail("an API path holds no //, # or spaces: " + shown($path));
    }
    for (def segment in strings.split($route, "/")) {
        if ($segment == "." or $segment == "..") {
            fail("an API path has no . or .. segments: " + shown($path));
        }
    }
}

/**
 * Call any endpoint of the API with the client's credentials.
 *
 * @param c {Client} the client
 * @param method {string} `GET`, `POST`, `PUT`, `PATCH` or `DELETE`
 * @param path {string} the path under the base URL, starting `/api2/` or
 *   `/api/v2.1/`, query string included, e.g. `/api2/repos/<id>/owner/`
 * @param body {string} the JSON body; "" for none
 * @return {json.Value} the reply; JSON `null` when it is empty
 * @throws {Error} kind `"seafile"` on a bad path, a network failure, a reply
 *   that is not 2xx (the message names the status and the server's reason),
 *   a 2xx reply that is not JSON, or a reply over the client's reply limit
 * @example
 *   def h as json.Value init seafile.call($c, "GET", "/api2/repos/" + $id + "/history-limit/", "");
 */
export func call(c as Client, method as string, path as string, body as string) {
    def verb as string init strings.upper($method);
    if (not lists.contains(["GET", "POST", "PUT", "PATCH", "DELETE"], $verb)) {
        fail("unsupported method " + shown($method));
    }
    ensureRoute($path);
    return api($c, $verb, $path, $body);
}

/**
 * A query parameter, the value percent-encoded.
 *
 * @param name {string} the name
 * @param value {string} the value
 * @return {string} `name=value`
 */
func param(name as string, value as string) {
    return $name + "=" + uri.encode($value);
}

/**
 * Build a JSON object from text members.
 *
 * @param fields {map of string to string} the members, all sent
 * @return {json.Value} the object
 */
func objectOf(fields as map of string to string) {
    def doc as json.Value init json.decode('{}');
    for (def key in $fields) {
        $doc = json.set($doc, "/" + $key, $fields[$key]);
    }
    return $doc;
}

/**
 * Refuse a verb a library API token cannot reach.
 *
 * @param c {Client} the client
 * @param what {string} the verb, for the error message
 */
func accountOnly(c as Client, what as string) {
    if ($c.repoToken) {
        fail($what + " needs an account token, not a library API token");
    }
}

/**
 * Check a library id for a verb both token kinds reach. With an account
 * token it must be a valid id; with a library API token it must be "" or
 * the client's library (when set).
 *
 * @param c {Client} the client
 * @param repoId {string} the id
 * @return {string} the id
 */
func repoFor(c as Client, repoId as string) {
    if (not $c.repoToken) {
        return checkRepoId($repoId);
    }
    if ($repoId != "") {
        checkRepoId($repoId);
        if ($c.repoId != "" and $repoId != $c.repoId) {
            fail("this client's library API token is for library " + $c.repoId + ", not " +
                $repoId);
        }
    }
    return $repoId;
}

/**
 * The route of a file or folder operation, for either token kind:
 * `/api/v2.1/repos/<id>/<kind>/?p=<path>` or
 * `/api/v2.1/via-repo-token/<kind>/?path=<path>`.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param kind {string} `file` or `dir`
 * @param path {string} the path
 * @return {string} the route
 */
func itemRoute(c as Client, repoId as string, kind as string, path as string) {
    def id as string init repoFor($c, $repoId);
    if ($c.repoToken) {
        return VIA + "/" + $kind + "/?" + param("path", checkPath($path));
    }
    return V21 + "/repos/" + $id + "/" + $kind + "/?" + param("p", checkPath($path));
}

/**
 * The route under one library in the account API.
 *
 * @param root {string} `API2` or `V21`
 * @param repoId {string} the library
 * @param rest {string} the rest, starting with `/`
 * @return {string} `<root>/repos/<id><rest>`
 */
func repoRoute(root as string, repoId as string, rest as string) {
    return $root + "/repos/" + checkRepoId($repoId) + $rest;
}

/**
 * Obtain an account token with a user name and password. The password is
 * sent to the server (over `https://`, or `http://` only under the rule of
 * `withPlainHttp`); the token returned stays valid until it is revoked.
 *
 * @param c {Client} the client; its own token is not sent
 * @param username {string} the login: e-mail address or login id
 * @param password {string} the password
 * @param otp {string} the current two-factor code; "" without 2FA
 * @return {string} the token, for `withToken`
 * @throws {Error} kind `"seafile"` on empty or malformed input, wrong
 *   credentials (HTTP 400), or as `call`
 */
export func login(c as Client, username as string, password as string, otp as string) {
    checkText($username, "user name");
    checkText($password, "password");
    if ($otp != "" and not regex.matches('^[0-9]{4,10}$', $otp)) {
        fail("a two-factor code is digits");
    }
    guardPlain($c, $c.url, "passwords");
    def route as string init API2 + "/auth-token/";
    def headers as map of string to string init {
        "Accept": "application/json",
        "Content-Type": "application/json"
    };
    if ($otp != "") {
        $headers["X-SEAFILE-OTP"] = $otp;
    }
    def o as http.Options;
    $o.tls = $c.tls;
    $o.timeoutMs = $c.timeoutMs;
    $o.maxBytes = replyCap($c);
    def body as string init json.encode(objectOf({"username": $username, "password": $password}));
    def r as http.Response;
    try {
        $r = http.send("POST", $c.url + $route, $headers, $body, $o);
    } catch (e) {
        # a body over its limit stays a reached cap
        if ($e.kind == "limit") {
            throw Error{kind: "limit", message: "seafile: POST " + $route + ": " + $e.message};
        }
        fail("POST " + $route + ": " + $e.message);
    }
    if (not isOk($r.status)) {
        failHttp("POST " + $route, $r.status, $r.statusText, $r.body, "");
    }
    def token as string init field(decoded($r.body, "POST " + $route), "/token");
    if ($token == "") {
        fail("POST " + $route + ": the reply holds no token");
    }
    return $token;
}

/**
 * The server's version and features. Needs no credentials; sends them when
 * the client has some.
 *
 * @param c {Client} the client
 * @return {ServerInfo} the info
 * @throws {Error} kind `"seafile"` as `call`
 */
export func serverInfo(c as Client) {
    def d as json.Value init api($c, "GET", API2 + "/server-info/", "");
    def info as ServerInfo;
    $info.version = field($d, "/version");
    $info.encryptedLibraryVersion = numberAt($d, "/encrypted_library_version");
    for (def p in items($d, "/features")) {
        $info.features[] = field($d, $p);
    }
    return $info;
}

/**
 * The account the token belongs to.
 *
 * @param c {Client} the client, with an account token
 * @return {Account} the account; `usage` and `total` read leniently (the
 *   reference shows them as strings such as `"22020651,"`)
 * @throws {Error} kind `"seafile"` without valid credentials (HTTP 401), or
 *   as `call`
 */
export func account(c as Client) {
    accountOnly($c, "account");
    def d as json.Value init api($c, "GET", API2 + "/account/info/", "");
    return Account{
        email: field($d, "/email"),
        name: field($d, "/name"),
        loginId: field($d, "/login_id"),
        contactEmail: field($d, "/contact_email"),
        institution: field($d, "/institution"),
        department: field($d, "/department"),
        isStaff: flag($d, "/is_staff"),
        usage: leadingInt($d, "/usage"),
        total: leadingInt($d, "/total")
    };
}

/**
 * A library from a reply. Reads the list and detail shape (`id`, `name`,
 * `size`) and the create shape (`repo_id`, `repo_name`, `repo_size`).
 *
 * @param d {json.Value} the document
 * @param p {string} the library's pointer; "" for the root
 * @return {Library} the library
 */
func libraryFrom(d as json.Value, p as string) {
    def id as string init field($d, $p + "/id");
    if ($id == "") {
        $id = field($d, $p + "/repo_id");
    }
    def name as string init field($d, $p + "/name");
    if ($name == "") {
        $name = field($d, $p + "/repo_name");
    }
    def size as int init numberAt($d, $p + "/size");
    if (json.typeOf($d, $p + "/size") == "missing") {
        $size = numberAt($d, $p + "/repo_size");
    }
    def enc as string init field($d, $p + "/encrypted");
    return Library{
        id: $id,
        name: $name,
        type: field($d, $p + "/type"),
        owner: field($d, $p + "/owner"),
        size: $size,
        mtime: timeAt($d, $p + "/mtime"),
        encrypted: $enc == "true" or $enc == "1",
        permission: field($d, $p + "/permission")
    };
}

/**
 * The libraries the account reaches.
 *
 * @param c {Client} the client
 * @param type {string} one of `LIBRARY_TYPES`, or "" for all
 * @return {list of Library} the libraries
 * @throws {Error} kind `"seafile"` on a bad type, or as `call`
 */
export func libraries(c as Client, type as string) {
    accountOnly($c, "libraries");
    def route as string init API2 + "/repos/";
    if ($type != "") {
        $route = $route + "?type=" + checkOneOf($type, LIBRARY_TYPES, "library type");
    }
    def d as json.Value init api($c, "GET", $route, "");
    def out as list of Library init [];
    for (def p in items($d, "")) {
        $out[] = libraryFrom($d, $p);
    }
    return $out;
}

/**
 * One library.
 *
 * @param c {Client} the client
 * @param id {string} the library id
 * @return {Library} the library
 * @throws {Error} kind `"seafile"` on a bad id, when it does not exist
 *   (HTTP 404), or as `call`
 */
export func library(c as Client, id as string) {
    accountOnly($c, "library");
    return libraryFrom(api($c, "GET", repoRoute(API2, $id, "/"), ""), "");
}

/**
 * The library a library API token belongs to (`via-repo-token/repo-info`).
 *
 * @param c {Client} the client, from `withRepoToken`
 * @return {Library} the id and name; the other fields are zero
 * @throws {Error} kind `"seafile"` with an account token, or as `call`
 */
export func tokenLibrary(c as Client) {
    if (not $c.repoToken) {
        fail("tokenLibrary needs a library API token");
    }
    return libraryFrom(api($c, "GET", VIA + "/repo-info/", ""), "");
}

/**
 * Create a library.
 *
 * @param c {Client} the client
 * @param name {string} the name
 * @param password {string} "" for a plain library; else the library is
 *   encrypted with this password, which is sent to the server
 * @return {Library} the new library
 * @throws {Error} kind `"seafile"` on a bad name, or as `call`
 */
export func createLibrary(c as Client, name as string, password as string) {
    accountOnly($c, "createLibrary");
    def fields as map of string to string init {"name": checkText($name, "library name")};
    if ($password != "") {
        $fields["passwd"] = $password;
    }
    def d as json.Value init api($c, "POST", API2 + "/repos/", json.encode(objectOf($fields)));
    return libraryFrom($d, "");
}

/**
 * Rename a library.
 *
 * @param c {Client} the client
 * @param id {string} the library
 * @param name {string} the new name
 * @throws {Error} kind `"seafile"` on a bad id or name, or as `call`
 */
export func renameLibrary(c as Client, id as string, name as string) {
    accountOnly($c, "renameLibrary");
    def form as string init "repo_name=" + uri.encodeForm(checkText($name, "library name"));
    apiForm($c, "POST", repoRoute(API2, $id, "/?op=rename"), $form);
}

/**
 * Delete a library with everything in it. A system admin can restore it
 * for a while (admin API, not in this deck).
 *
 * @param c {Client} the client
 * @param id {string} the library
 * @throws {Error} kind `"seafile"` on a bad id, or as `call`
 */
export func removeLibrary(c as Client, id as string) {
    accountOnly($c, "removeLibrary");
    api($c, "DELETE", repoRoute(API2, $id, "/"), "");
}

/**
 * Unlock an encrypted library for this account on the server, so the API
 * can read and write its files. The password is sent to the server, which
 * keeps the decrypted key in memory for a time its settings decide.
 *
 * @param c {Client} the client
 * @param id {string} the library
 * @param password {string} the library's password
 * @throws {Error} kind `"seafile"` on a wrong password (HTTP 400), or as
 *   `call`
 */
export func decrypt(c as Client, id as string, password as string) {
    accountOnly($c, "decrypt");
    def form as string init "password=" + uri.encodeForm(checkText($password, "password"));
    apiForm($c, "POST", repoRoute(API2, $id, "/"), $form);
}

/**
 * A file or folder from a reply: the listing shape (`name`, `id`,
 * `parent_dir`, `mtime` in seconds) or the detail shape (`obj_name`,
 * `obj_id`, `mtime` as ISO 8601).
 *
 * @param d {json.Value} the item itself
 * @param dir {string} the folder it is in when the item names none
 * @return {Entry} the entry
 */
func entryFrom(d as json.Value, dir as string) {
    def name as string init field($d, "/name");
    if ($name == "") {
        $name = field($d, "/obj_name");
    }
    def parent as string init $dir;
    if (json.typeOf($d, "/parent_dir") == "string") {
        $parent = json.asString($d, "/parent_dir");
    }
    def id as string init field($d, "/id");
    if ($id == "") {
        $id = field($d, "/obj_id");
    }
    def modifier as string init field($d, "/modifier_email");
    if ($modifier == "") {
        $modifier = field($d, "/last_modifier_email");
    }
    def type as string init field($d, "/type");
    if ($type == "") {
        $type = "file";
    }
    return Entry{
        name: $name,
        path: joined($parent, $name),
        type: $type,
        id: $id,
        size: numberAt($d, "/size"),
        mtime: timeAt($d, "/mtime"),
        permission: field($d, "/permission"),
        starred: flag($d, "/starred"),
        isLocked: flag($d, "/is_locked"),
        modifier: $modifier
    };
}

/**
 * A listing item, the hot path of `listDir`: the fields every listing item
 * carries read with the typed `json.as*` calls (one pointer walk each), the
 * optional flags after a `json.typeOf`. Any absent or differently typed
 * field falls back to `entryFrom`.
 *
 * @param d {json.Value} the item itself
 * @param dir {string} the folder listed
 * @return {Entry} the entry
 */
func listedEntry(d as json.Value, dir as string) {
    try {
        def name as string init json.asString($d, "/name");
        def type as string init json.asString($d, "/type");
        def size as int init 0;
        def modifier as string init "";
        if ($type == "file") {
            $size = json.asInt($d, "/size");
            $modifier = json.asString($d, "/modifier_email");
        }
        def starred as bool init false;
        if (json.typeOf($d, "/starred") == "bool") {
            $starred = json.asBool($d, "/starred");
        }
        def locked as bool init false;
        if (json.typeOf($d, "/is_locked") == "bool") {
            $locked = json.asBool($d, "/is_locked");
        }
        return Entry{
            name: $name,
            path: joined(json.asString($d, "/parent_dir"), $name),
            type: $type,
            id: json.asString($d, "/id"),
            size: $size,
            mtime: json.asInt($d, "/mtime"),
            permission: json.asString($d, "/permission"),
            starred: $starred,
            isLocked: $locked,
            modifier: $modifier
        };
    } catch (e) {
        return entryFrom($d, $dir);
    }
    return entryFrom($d, $dir);
}

/**
 * The type filter of a listing.
 *
 * @param type {string} "", `file` or `dir`
 * @return {string} "", `f` or `d`
 */
func typeLetter(type as string) {
    if ($type == "") {
        return "";
    }
    return strings.substring(checkOneOf($type, ["file", "dir"], "listing type"), 0, 1);
}

/**
 * The entries of a folder.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the folder, `/` for the root
 * @param type {string} `file` or `dir` for only those, "" for both
 * @param recursive {bool} every depth below the folder, in one request
 * @return {list of Entry} the entries, with their full paths
 * @throws {Error} kind `"seafile"` when it does not exist (HTTP 404), or as
 *   `call`; a reply over the client's reply limit is refused
 */
export func listDir(
    c as Client,
    repoId as string,
    path as string,
    type as string,
    recursive as bool) {
    def route as string init itemRoute($c, $repoId, "dir", $path);
    def letter as string init typeLetter($type);
    if ($letter != "") {
        if ($c.repoToken) {
            $route = $route + "&type=" + $letter;
        } else {
            $route = $route + "&t=" + $letter;
        }
    }
    if ($recursive) {
        $route = $route + "&recursive=1";
    }
    def d as json.Value init api($c, "GET", $route, "");
    def out as list of Entry init [];
    for (def p in items($d, "/dirent_list")) {
        $out[] = listedEntry(json.get($d, $p), $path);
    }
    return $out;
}

/**
 * A folder's detail.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder
 * @return {Entry} the folder; `id`, `size` and `modifier` are not reported
 * @throws {Error} kind `"seafile"` when it does not exist, or as `call`
 */
export func dirDetail(c as Client, repoId as string, path as string) {
    accountOnly($c, "dirDetail");
    def route as string init repoRoute(
        V21,
        $repoId,
        "/dir/detail/?" + param("path", checkPath($path)));
    def d as json.Value init api($c, "GET", $route, "");
    def e as Entry init entryFrom($d, "/");
    $e.path = $path;
    $e.type = "dir";
    return $e;
}

/**
 * A file's detail.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file
 * @return {Entry} the file
 * @throws {Error} kind `"seafile"` when it does not exist or is a folder
 *   (HTTP 404), or as `call`
 */
export func fileDetail(c as Client, repoId as string, path as string) {
    def d as json.Value init api(
        $c,
        "GET",
        itemRoute($c, $repoId, "file", checkItem($path, "a file")),
        "");
    def e as Entry init entryFrom($d, parentOf($path));
    $e.path = $path;
    return $e;
}

/**
 * Whether a reply says the file or folder is not there: 404 with an
 * `error_msg` that starts `File ` or `Folder `. A 404 for a missing library
 * says nothing about the path.
 *
 * @param r {http.Response} the reply
 * @return {bool} whether it is missing
 */
func isMissing(r as http.Response) {
    if ($r.status != 404) {
        return false;
    }
    def said as string init serverReason($r.body);
    return strings.startsWith($said, "File ") or strings.startsWith($said, "Folder ");
}

/**
 * Probe a route: true on 2xx, false when `isMissing`, a throw otherwise.
 *
 * @param c {Client} the client
 * @param route {string} the route
 * @return {bool} whether it is there
 */
func probe(c as Client, route as string) {
    def r as http.Response init sendRaw($c, "GET", $route, "", "");
    if (isMissing($r)) {
        return false;
    }
    if (not isOk($r.status)) {
        failHttp("GET " + $route, $r.status, $r.statusText, $r.body, "");
    }
    return true;
}

/**
 * Whether a folder exists: `dir/detail`, or with a library API token a
 * listing of its sub-folders.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the folder
 * @return {bool} whether it is a folder
 */
func isDir(c as Client, repoId as string, path as string) {
    if ($c.repoToken) {
        return probe($c, itemRoute($c, $repoId, "dir", $path) + "&type=d");
    }
    return probe($c, repoRoute(V21, $repoId, "/dir/detail/?" + param("path", checkPath($path))));
}

/**
 * Whether a file or folder exists. Asks for the file first, then for a
 * folder: one request for a file or `/`, two otherwise.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the path; `/` is always there
 * @return {bool} false when the server answers 404 `File ... not found` and
 *   `Folder ... not found`
 * @throws {Error} kind `"seafile"` on any other refusal (a missing library
 *   included), or as `call`
 */
export func exists(c as Client, repoId as string, path as string) {
    if (checkPath($path) == "/") {
        return isDir($c, $repoId, $path);
    }
    if (probe($c, itemRoute($c, $repoId, "file", $path))) {
        return true;
    }
    return isDir($c, $repoId, $path);
}

/**
 * Make a folder. Without `parents` its parent must exist, and a taken name
 * gets a free one (`x (1)`), as Seafile does: the path returned is the
 * folder made. With `parents` every missing folder on the way is made and a
 * folder that exists is left as it is.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the folder, e.g. `/backups/2026`
 * @param parents {bool} make missing parents too (`create_parents`); with a
 *   library API token, one probe per level and a `mkdir` per missing one
 * @return {string} the path of the folder
 * @throws {Error} kind `"seafile"` on the root, when the parent is missing
 *   (without `parents`), when part of the path is a file, or as `call`
 */
export func mkdir(c as Client, repoId as string, path as string, parents as bool) {
    checkItem($path, "made");
    if ($parents and not $c.repoToken) {
        def form as string init "operation=mkdir&create_parents=true";
        apiForm($c, "POST", repoRoute(API2, $repoId, "/dir/?" + param("p", $path)), $form);
        return $path;
    }
    if ($parents) {
        return mkdirParents($c, $repoId, $path);
    }
    def d as json.Value init api(
        $c,
        "POST",
        itemRoute($c, $repoId, "dir", $path),
        json.encode(objectOf({"operation": "mkdir"})));
    return joined(parentOf($path), field($d, "/obj_name"));
}

/**
 * `mkdir` with parents for a library API token: probe each level from the
 * top, make the first missing one and every one below.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the folder
 * @return {string} the path
 */
func mkdirParents(c as Client, repoId as string, path as string) {
    def at as string init "/";
    def probing as bool init true;
    for (def segment in strings.split(strings.substring($path, 1, len($path)), "/")) {
        $at = joined($at, $segment);
        if ($probing) {
            $probing = isDir($c, $repoId, $at);
        }
        if (not $probing) {
            def made as string init mkdir($c, $repoId, $at, false);
            if ($made != $at) {
                fail(shown($at) + " is taken by a file; the folder became " + shown($made));
            }
        }
    }
    return $path;
}

/**
 * The link a link endpoint returned, checked: a JSON string, an `http[s]`
 * URL on the base URL's origin or on `fileServer`, and not over plain
 * `http://` to a host that is not loopback without `plainHttp`.
 *
 * @param c {Client} the client
 * @param d {json.Value} the reply
 * @param what {string} the request, for the error message
 * @return {string} the link
 */
func transferLink(c as Client, d as json.Value, what as string) {
    if (json.typeOf($d) != "string") {
        fail($what + ": the reply is not a link");
    }
    def link as string init json.asString($d);
    def u as uri.Uri init urlParts($link, "transfer link");
    def origin as string init originOf($u);
    def base as string init originOf(urlParts($c.url, "base URL"));
    if ($origin != $base and $origin != $c.fileServer) {
        fail($what + ": the server handed out a link to " + shown($origin) + ", not " +
            shown($base) +
            "; withFileServer allows another origin");
    }
    guardPlain($c, $link, "transfer links");
    return $link;
}

/**
 * Ask the API for a transfer link.
 *
 * @param c {Client} the client
 * @param route {string} the link endpoint
 * @return {string} the checked link
 */
func linkFrom(c as Client, route as string) {
    return transferLink($c, api($c, "GET", $route, ""), "GET " + $route);
}

/**
 * A link with a query parameter added.
 *
 * @param link {string} the link
 * @param query {string} `name=value`
 * @return {string} the link
 */
func withQuery(link as string, query as string) {
    if (strings.contains($link, "?")) {
        return $link + "&" + $query;
    }
    return $link + "?" + $query;
}

/**
 * Download a file. Two requests: the download link from the API, then the
 * file from `/seafhttp/`, without `Authorization`. `maxBytes` caps the
 * body.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file
 * @param maxBytes {int} the largest file accepted; 0 for `DOWNLOAD_LIMIT`,
 *   negative for no limit
 * @return {bytes} the content
 * @throws {Error} kind `"seafile"` on a bad path, when it does not exist, on
 *   a link on a foreign origin, on a refusal or network failure, or for a
 *   file over `maxBytes`
 */
export func get(c as Client, repoId as string, path as string, maxBytes as int) {
    checkItem($path, "downloaded");
    def route as string init "";
    if ($c.repoToken) {
        repoFor($c, $repoId);
        $route = VIA + "/download-link/?" + param("path", $path);
    } else {
        $route = repoRoute(API2, $repoId, "/file/?" + param("p", $path));
    }
    def link as string init linkFrom($c, $route);
    def cap as int init $maxBytes;
    if ($cap == 0) {
        $cap = DOWNLOAD_LIMIT;
    }
    def r as http.BytesResponse;
    try {
        $r = http.requestWithBytes("GET", $link, {"Accept": "*/*"}, "", idleMs($c), $cap, $c.tls);
    } catch (e) {
        # a body over its limit stays a reached cap
        if ($e.kind == "limit") {
            throw Error{
                kind: "limit",
                message: "seafile: GET " + transferName($link) + ": " + $e.message
            };
        }
        fail("GET " + transferName($link) + ": " + $e.message);
    }
    if (not isOk($r.status)) {
        def text as string init "";
        try {
            $text = convert.stringFromBytes("utf-8", $r.body);
        } catch (e) {
            $text = "";
        }
        failHttp("GET " + transferName($link), $r.status, $r.statusText, $text, "");
    }
    return $r.body;
}

/**
 * A transfer link as an error message names it: the path up to the kind of
 * transfer, without the token that follows.
 *
 * @param link {string} the link
 * @return {string} e.g. `/seafhttp/files/...`
 */
func transferName(link as string) {
    def kept as list of string init [];
    def take as int init 1;
    for (def segment in strings.split(uri.parse($link).path, "/")) {
        if ($segment == "") {
            continue;
        }
        $kept[] = $segment;
        if ($segment == "seafhttp") {
            $take = len($kept) + 1;
        }
        if (len($kept) >= $take and $take > 1) {
            break;
        }
    }
    if ($take == 1 and len($kept) > 1) {
        $kept = lists.slice($kept, 0, 1);
    }
    return "/" + strings.join($kept, "/") + "/...";
}

/**
 * The upload link of a folder.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param dir {string} the folder
 * @return {string} the checked link
 */
func uploadLink(c as Client, repoId as string, dir as string) {
    if ($c.repoToken) {
        repoFor($c, $repoId);
        return linkFrom($c, VIA + "/upload-link/?" + param("path", $dir));
    }
    return linkFrom($c, repoRoute(API2, $repoId, "/upload-link/?" + param("p", $dir)));
}

/**
 * POST a multipart body to a transfer link, without `Authorization`.
 *
 * @param c {Client} the client
 * @param link {string} the link, query included
 * @param parts {list of multipart.Part} the form
 * @param extra {map of string to string} further headers
 * @return {http.Response} the reply, whatever its status
 */
func postRaw(
    c as Client,
    link as string,
    parts as list of multipart.Part,
    extra as map of string to string) {
    def built as multipart.Built init multipart.build($parts);
    def headers as map of string to string init $extra;
    $headers["Accept"] = "application/json";
    $headers["Content-Type"] = $built.contentType;
    def r as http.Response;
    try {
        $r = http.requestRawBodyTls(
            "POST",
            $link,
            $headers,
            $built.body,
            idleMs($c),
            replyCap($c),
            $c.tls);
    } catch (e) {
        # a body over its limit stays a reached cap
        if ($e.kind == "limit") {
            throw Error{
                kind: "limit",
                message: "seafile: POST " + transferName($link) + ": " + $e.message
            };
        }
        fail("POST " + transferName($link) + ": " + $e.message);
    }
    return $r;
}

/**
 * POST a multipart body to a transfer link, without `Authorization`.
 *
 * @param c {Client} the client
 * @param link {string} the link, query included
 * @param parts {list of multipart.Part} the form
 * @param extra {map of string to string} further headers
 * @return {http.Response} the reply, refused unless 2xx
 */
func postParts(
    c as Client,
    link as string,
    parts as list of multipart.Part,
    extra as map of string to string) {
    def r as http.Response init postRaw($c, $link, $parts, $extra);
    if (not isOk($r.status)) {
        failHttp("POST " + transferName($link), $r.status, $r.statusText, $r.body, "");
    }
    return $r;
}

/**
 * The file an upload stored, from its `ret-json` reply `[{name, id, size}]`.
 *
 * @param r {http.Response} the reply
 * @param link {string} the link, for the error message
 * @param dir {string} the folder
 * @return {Entry} the stored file
 */
func uploaded(r as http.Response, link as string, dir as string) {
    def d as json.Value init decoded($r.body, "POST " + transferName($link));
    if (json.typeOf($d, "/0/name") != "string") {
        fail("POST " + transferName($link) + ": the reply names no file");
    }
    def e as Entry;
    $e.name = json.asString($d, "/0/name");
    $e.path = joined($dir, $e.name);
    $e.type = "file";
    $e.id = field($d, "/0/id");
    $e.size = numberAt($d, "/0/size");
    return $e;
}

/**
 * The form of an upload.
 *
 * @param dir {string} the folder
 * @param name {string} the file name
 * @param data {bytes} the content
 * @param replace {bool} overwrite an existing file
 * @return {list of multipart.Part} the parts
 */
func uploadParts(dir as string, name as string, data as bytes, replace as bool) {
    def replaceFlag as string init "0";
    if ($replace) {
        $replaceFlag = "1";
    }
    return [
        multipart.field("parent_dir", $dir),
        multipart.field("replace", $replaceFlag),
        multipart.file("file", $name, "application/octet-stream", $data)
    ];
}

/**
 * Upload a file: the upload link from the API, then a multipart POST to it
 * (`parent_dir`, `replace`, `file`), without `Authorization`. The folder
 * must exist; see `mkdir`.
 *
 * With an account token it first asks `file-uploaded-bytes` and drops a
 * temp file a chunked upload left at that path (see `putResumable`), so a
 * later resume cannot join its stale bytes: one request more, three more
 * when there is one. The temp file is keyed by library and path, not by
 * client: this aborts a chunked upload of the same path that another
 * client has in progress. The drop is best effort: when the update link
 * or the drop fails (a share that allows upload but not web edit answers
 * 403), the upload goes ahead, bypasses the temp file and leaves it. A
 * library token cannot ask and leaves such a file.
 *
 * The C fileserver (the Community Edition default) reads a multipart file
 * name verbatim, without unescaping, and cuts it at the last `\`. A name
 * with `"` is therefore sent as one chunk (as `putResumable`), whose
 * percent-encoded header both fileservers decode; a name with `\` is
 * refused.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file, e.g. `/docs/a.txt`
 * @param data {bytes} the content
 * @param replace {bool} overwrite a file of that name; false stores the
 *   upload under a free name (`a (1).txt`) instead, as Seafile does
 * @return {Entry} the stored file: `name` and `path` show the name it got;
 *   `mtime`, `permission` and `modifier` are not reported
 * @throws {Error} kind `"seafile"` on a bad path, a name with `\`, an empty
 *   file named with `"`, a missing folder, a link on a foreign origin, or a
 *   refusal or network failure
 */
export func put(c as Client, repoId as string, path as string, data as bytes, replace as bool) {
    checkItem($path, "a file");
    checkUploadName($path);
    if (strings.contains(nameOf($path), "\"")) {
        if (len($data) == 0) {
            fail("an empty file cannot be named with \", got " + shown($path));
        }
        return chunked($c, $repoId, $path, $data, len($data), $replace, false);
    }
    def held as int init uploadedBytes($c, $repoId, parentOf($path), nameOf($path));
    return putHeld($c, $repoId, $path, $data, $replace, $held);
}

/**
 * Refuse an upload name with `\`: the C fileserver keeps only what follows
 * the last one, so the data would land in another file.
 *
 * @param path {string} the checked file path
 */
func checkUploadName(path as string) {
    if (strings.contains(nameOf($path), "\\")) {
        fail("an uploaded file name cannot hold \\ (the fileserver cuts it there), got " +
            shown($path));
    }
}

/**
 * `put` once the temp file's size is known: drop it (best effort), then a
 * plain multipart upload of the whole data in one request.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the checked file path
 * @param data {bytes} the content
 * @param replace {bool} overwrite a file of that name
 * @param held {int} the temp file's size; 0 for none
 * @return {Entry} the stored file
 */
func putHeld(
    c as Client,
    repoId as string,
    path as string,
    data as bytes,
    replace as bool,
    held as int) {
    def dir as string init parentOf($path);
    if ($held > 0) {
        # Best effort: the plain upload below bypasses the temp file.
        tryDrop($c, $repoId, "", $path, $held);
    }
    def link as string init withQuery(uploadLink($c, $repoId, $dir), "ret-json=1");
    def r as http.Response init postParts(
        $c,
        $link,
        uploadParts($dir, nameOf($path), $data, $replace),
        {});
    return uploaded($r, $link, $dir);
}

/**
 * The update link of a folder (account token).
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param dir {string} the folder
 * @return {string} the checked link
 */
func updateLink(c as Client, repoId as string, dir as string) {
    return linkFrom($c, repoRoute(API2, $repoId, "/update-link/?" + param("p", $dir)));
}

/**
 * Drop the temp file at a path: the folder's update link, then `dropTemp`.
 * Two requests.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the file
 * @param held {int} the temp file's size, > 0
 * @throws {Error} kind `"seafile"` when the link cannot be had or the drop
 *   is not sent
 */
func dropHeld(c as Client, repoId as string, path as string, held as int) {
    dropTemp($c, updateLink($c, $repoId, parentOf($path)), $path, $held);
}

/**
 * `dropHeld`, best effort: a failure is ignored.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param link {string} the folder's update link; "" to ask for it
 * @param path {string} the file
 * @param held {int} the temp file's size, > 0
 * @return {bool} whether the drop was sent
 */
func tryDrop(c as Client, repoId as string, link as string, path as string, held as int) {
    try {
        if ($link == "") {
            dropHeld($c, $repoId, $path, $held);
        } else {
            dropTemp($c, $link, $path, $held);
        }
    } catch (e) {
        return false;
    }
    return true;
}

/**
 * Drop the temp file of a chunked upload. The fileserver keeps one per
 * library and path and appends a chunk only at its size. One byte at that
 * offset to the update link completes it; the unknown `head` commit (read
 * from the query) then fails the update with 500, and both fileservers
 * delete the temp file and its record on that failure (C `update_api_cb`
 * and `upload_finish_cb`, Go `clearTmpFile`). Nothing is stored. If the
 * temp file changed size meanwhile the chunk is refused as a bad offset,
 * which stores nothing either. The reply is not checked: the upload that
 * follows does not depend on it.
 *
 * @param c {Client} the client
 * @param link {string} the folder's update link
 * @param path {string} the file
 * @param held {int} the temp file's size, > 0
 */
func dropTemp(c as Client, link as string, path as string, held as int) {
    def name as string init nameOf($path);
    def at as string init convert.toString($held);
    postRaw(
        $c,
        withQuery($link, "head=" + NO_COMMIT),
        [
            multipart.field("target_file", $path),
            multipart.file(
                "file",
                $name,
                "application/octet-stream",
                convert.bytesFromString("utf-8", "x"))
        ],
        {
            "Content-Range": "bytes " + $at + "-" + $at + "/" + convert.toString($held + 1),
            "Content-Disposition": "attachment; filename=\"" + uri.encode($name) + "\""
        });
}

/**
 * Overwrite an existing file in place (`update-link`): a new version of the
 * same file. It must exist; `put` with `replace` creates or overwrites.
 * Drops a chunked upload's temp file at that path first, as `put`: one
 * request more, two more when there is one. This aborts another client's
 * chunked upload of that path. The drop is best effort: when it fails, the
 * update goes ahead and the temp file remains.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the file
 * @param data {bytes} the new content
 * @return {string} the new file object id (the server answers it as bare
 *   text, not JSON)
 * @throws {Error} kind `"seafile"` when the file is missing, or as `put`
 */
export func update(c as Client, repoId as string, path as string, data as bytes) {
    accountOnly($c, "update");
    checkItem($path, "a file");
    def dir as string init parentOf($path);
    def held as int init uploadedBytes($c, $repoId, $dir, nameOf($path));
    def link as string init updateLink($c, $repoId, $dir);
    if ($held > 0) {
        # Best effort: the update below bypasses the temp file.
        tryDrop($c, $repoId, $link, $path, $held);
    }
    def parts as list of multipart.Part init [
        multipart.field("target_file", $path),
        multipart.file("file", nameOf($path), "application/octet-stream", $data)
    ];
    def r as http.Response init postParts($c, $link, $parts, {});
    def id as string init strings.trim($r.body);
    if (strings.startsWith($id, "\"")) {
        $id = field(decoded($id, "POST " + transferName($link)), "");
    }
    if (not regex.matches('^[0-9a-f]{40}$', $id)) {
        fail("POST " + transferName($link) + ": the reply is not a file id");
    }
    return $id;
}

/**
 * How much of a resumable upload the server holds already.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param dir {string} the folder
 * @param name {string} the file name
 * @return {int} bytes stored, 0..`MAX_OFFSET`; 0 with a library API token
 *   (it has no such endpoint)
 * @throws {Error} kind `"seafile"` on a value outside 0..`MAX_OFFSET`, or as
 *   `call`
 */
func uploadedBytes(c as Client, repoId as string, dir as string, name as string) {
    if ($c.repoToken) {
        return 0;
    }
    def route as string init repoRoute(
        V21,
        $repoId,
        "/file-uploaded-bytes/?" +
            param("parent_dir", $dir) + "&" + param("file_name", $name));
    def held as int init numberAt(api($c, "GET", $route, ""), "/uploadedBytes");
    if ($held < 0 or $held > MAX_OFFSET) {
        fail("GET " + $route + ": uploadedBytes " + convert.toString($held) +
            " is out of range");
    }
    return $held;
}

/**
 * Upload a file in chunks to one upload link, each POST with
 * `Content-Range: bytes <first>-<last>/<total>` and
 * `Content-Disposition: attachment; filename="<percent-encoded name>"`.
 * The server keeps the chunks in a temp file keyed by library and path and
 * joins them after the last one; it accepts a chunk only at the temp file's
 * size and does not check its content.
 *
 * With `resume` false the upload starts fresh. A temp file left by an
 * earlier attempt (account token: `file-uploaded-bytes` reports one, of
 * any size) is dropped first, as `put` does, then the chunks go from 0:
 * two requests more. With a library token, which can neither ask nor drop,
 * a stale temp file answers HTTP 400 to the first chunk; the data then
 * goes through `put` in one POST of the whole data, which bypasses the
 * temp file and leaves it (a name with `"` throws instead, see `put`).
 *
 * With `resume` true the upload continues at the offset the server holds
 * (account token only; a library token starts at 0 as with `resume`
 * false). Resume only with the same data as the interrupted call: the
 * server joins whatever it holds with the rest. An offset equal to the size
 * (complete but never stored) drops the temp file and starts at 0; one
 * above the size throws.
 *
 * Account token: when the first chunk answers HTTP 400 (a temp file
 * appeared or changed after the offset was read), the offset is read
 * again, the temp file dropped and the upload restarted at 0, once; a
 * second 400 throws. Dropping aborts a chunked upload of the same path
 * that another client has in progress (the key is library and path).
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file
 * @param data {bytes} the whole content
 * @param chunkSize {int} bytes per request; 0 for `CHUNK_SIZE`
 * @param replace {bool} overwrite a file of that name, as `put`
 * @param resume {bool} continue at the server's offset instead of starting
 *   fresh
 * @return {Entry} the stored file, as `put`
 * @throws {Error} kind `"seafile"` on a negative chunk size, a name with
 *   `\`, a reported offset above the size with `resume`, or as `put`
 */
export func putResumable(
    c as Client,
    repoId as string,
    path as string,
    data as bytes,
    chunkSize as int,
    replace as bool,
    resume as bool) {
    checkItem($path, "a file");
    checkUploadName($path);
    if ($chunkSize < 0) {
        fail("a chunk size is 0 or more, got " + convert.toString($chunkSize));
    }
    def size as int init $chunkSize;
    if ($size == 0) {
        $size = CHUNK_SIZE;
    }
    if (len($data) == 0) {
        return put($c, $repoId, $path, $data, $replace);
    }
    return chunked($c, $repoId, $path, $data, $size, $replace, $resume);
}

/**
 * The chunk loop of `putResumable`, also `put`'s for a name with `"`.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the checked file path
 * @param data {bytes} the whole content, not empty
 * @param size {int} bytes per chunk, > 0
 * @param replace {bool} overwrite a file of that name
 * @param resume {bool} continue at the server's offset
 * @return {Entry} the stored file
 */
func chunked(
    c as Client,
    repoId as string,
    path as string,
    data as bytes,
    size as int,
    replace as bool,
    resume as bool) {
    def total as int init len($data);
    def dir as string init parentOf($path);
    def name as string init nameOf($path);
    def at as int init uploadedBytes($c, $repoId, $dir, $name);
    if ($resume and $at > $total) {
        fail("the server holds " + convert.toString($at) + " bytes of " + shown($path) +
            ", the data " +
            convert.toString($total));
    }
    if ($at > 0 and (not $resume or $at >= $total)) {
        # The server refuses a chunk at 0 over a temp file, and every chunk
        # over a complete one.
        dropHeld($c, $repoId, $path, $at);
        $at = 0;
    }
    def link as string init withQuery(uploadLink($c, $repoId, $dir), "ret-json=1");
    def disposition as string init "attachment; filename=\"" + uri.encode($name) + "\"";
    def first as bool init true;
    def restarted as bool init false;
    while (true) {
        def end as int init $at + $size;
        if ($end > $total) {
            $end = $total;
        }
        def headers as map of string to string init {
            "Content-Range": "bytes " + convert.toString($at) + "-" + convert.toString($end - 1) +
                "/" +
                convert.toString($total),
            "Content-Disposition": $disposition
        };
        def parts as list of multipart.Part init uploadParts(
            $dir,
            $name,
            $data[$at..$end],
            $replace);
        def r as http.Response init postRaw($c, $link, $parts, $headers);
        # A 400 on the first chunk: a temp file the offset did not show (a
        # library token cannot ask, or one appeared since).
        def stale as bool init $first and $r.status == 400 and not $restarted;
        if ($stale and $c.repoToken) {
            if (strings.contains($name, "\"")) {
                failHttp(
                    "POST " + transferName($link),
                    $r.status,
                    $r.statusText,
                    $r.body,
                    " (a stale temp file a library token cannot drop)");
            }
            return putHeld($c, $repoId, $path, $data, $replace, 0);
        }
        if ($stale) {
            def held as int init uploadedBytes($c, $repoId, $dir, $name);
            if ($held > 0) {
                dropHeld($c, $repoId, $path, $held);
            }
            $restarted = true;
            $at = 0;
            continue;
        }
        if (not isOk($r.status)) {
            failHttp("POST " + transferName($link), $r.status, $r.statusText, $r.body, "");
        }
        if ($end == $total) {
            return uploaded($r, $link, $dir);
        }
        $first = false;
        $at = $end;
    }
    def none as Entry;
    return $none;
}

/**
 * Rename a file or folder in place. A taken name gets a free one
 * (`x (1)`), as Seafile does. Tries the file endpoint first, then the
 * folder endpoint: one request for a file, two for a folder.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file or folder
 * @param name {string} the new name, without `/`
 * @return {string} the new path, with the name it got
 * @throws {Error} kind `"seafile"` on the root, a bad name, when it does not
 *   exist, or as `call`
 */
export func rename(c as Client, repoId as string, path as string, name as string) {
    checkItem($path, "renamed");
    def body as string init json.encode(objectOf({
        "operation": "rename",
        "newname": checkName($name)
    }));
    def route as string init itemRoute($c, $repoId, "file", $path);
    def r as http.Response init sendRaw($c, "POST", $route, $body, "application/json");
    if (isMissing($r)) {
        $route = itemRoute($c, $repoId, "dir", $path);
        $r = sendRaw($c, "POST", $route, $body, "application/json");
    }
    if (not isOk($r.status)) {
        failHttp("POST " + $route, $r.status, $r.statusText, $r.body, "");
    }
    return joined(parentOf($path), field(decoded($r.body, "POST " + $route), "/obj_name"));
}

/**
 * The body of a batch copy or move.
 *
 * @param c {Client} the client
 * @param repoId {string} the source library
 * @param dir {string} the source folder
 * @param names {list of string} the items in it
 * @param toRepoId {string} the target library
 * @param toDir {string} the target folder
 * @return {string} the JSON
 */
func batchBody(
    c as Client,
    repoId as string,
    dir as string,
    names as list of string,
    toRepoId as string,
    toDir as string) {
    def doc as json.Value init json.decode('{}');
    def from as string init repoFor($c, $repoId);
    def target as string init repoFor($c, $toRepoId);
    if (not $c.repoToken) {
        $doc = json.set($doc, "/src_repo_id", $from);
        $doc = json.set($doc, "/dst_repo_id", $target);
    }
    $doc = json.set($doc, "/src_parent_dir", checkPath($dir));
    $doc = json.set($doc, "/src_dirents", json.list(checkNames($names)));
    $doc = json.set($doc, "/dst_parent_dir", checkPath($toDir));
    return json.encode($doc);
}

/**
 * Copy or move items in one folder, synchronously: the shared request.
 *
 * @param c {Client} the client
 * @param verb {string} `copy` or `move`
 * @param repoId {string} the source library
 * @param dir {string} the source folder
 * @param names {list of string} the items
 * @param toRepoId {string} the target library
 * @param toDir {string} the target folder
 */
func syncBatch(
    c as Client,
    verb as string,
    repoId as string,
    dir as string,
    names as list of string,
    toRepoId as string,
    toDir as string) {
    def body as string init batchBody($c, $repoId, $dir, $names, $toRepoId, $toDir);
    def route as string init V21 + "/repos/sync-batch-" + $verb + "-item/";
    if ($c.repoToken) {
        $route = VIA + "/sync-batch-" + $verb + "-item/";
    }
    api($c, "POST", $route, $body);
}

/**
 * Copy files and folders of one folder into a folder, in the same library
 * or another, and wait for it. A taken name in the target gets a free one.
 *
 * @param c {Client} the client
 * @param repoId {string} the source library
 * @param dir {string} the folder the items are in
 * @param names {list of string} the items' names
 * @param toRepoId {string} the target library (with a library API token,
 *   the same)
 * @param toDir {string} the target folder; it must exist
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func copyItems(
    c as Client,
    repoId as string,
    dir as string,
    names as list of string,
    toRepoId as string,
    toDir as string) {
    syncBatch($c, "copy", $repoId, $dir, $names, $toRepoId, $toDir);
}

/**
 * Move files and folders of one folder into a folder, in the same library
 * or another, and wait for it.
 *
 * @param c {Client} the client
 * @param repoId {string} the source library
 * @param dir {string} the folder the items are in
 * @param names {list of string} the items' names
 * @param toRepoId {string} the target library (with a library API token,
 *   the same)
 * @param toDir {string} the target folder; it must exist
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func moveItems(
    c as Client,
    repoId as string,
    dir as string,
    names as list of string,
    toRepoId as string,
    toDir as string) {
    syncBatch($c, "move", $repoId, $dir, $names, $toRepoId, $toDir);
}

/**
 * Copy one file or folder into a folder: `copyItems` with one item.
 *
 * @param c {Client} the client
 * @param repoId {string} the source library
 * @param path {string} the file or folder
 * @param toRepoId {string} the target library
 * @param toDir {string} the target folder
 * @throws {Error} kind `"seafile"` on the root, or as `copyItems`
 */
export func copy(
    c as Client,
    repoId as string,
    path as string,
    toRepoId as string,
    toDir as string) {
    checkItem($path, "copied");
    syncBatch($c, "copy", $repoId, parentOf($path), [nameOf($path)], $toRepoId, $toDir);
}

/**
 * Move one file or folder into a folder: `moveItems` with one item.
 *
 * @param c {Client} the client
 * @param repoId {string} the source library
 * @param path {string} the file or folder
 * @param toRepoId {string} the target library
 * @param toDir {string} the target folder
 * @throws {Error} kind `"seafile"` on the root, or as `moveItems`
 */
export func move(
    c as Client,
    repoId as string,
    path as string,
    toRepoId as string,
    toDir as string) {
    checkItem($path, "moved");
    syncBatch($c, "move", $repoId, parentOf($path), [nameOf($path)], $toRepoId, $toDir);
}

/**
 * Start an async copy or move: the shared request.
 *
 * @param c {Client} the client
 * @param verb {string} `copy` or `move`
 * @param repoId {string} the source library
 * @param dir {string} the source folder
 * @param names {list of string} the items
 * @param toRepoId {string} the target library
 * @param toDir {string} the target folder
 * @return {string} the task id
 */
func asyncBatch(
    c as Client,
    verb as string,
    repoId as string,
    dir as string,
    names as list of string,
    toRepoId as string,
    toDir as string) {
    accountOnly($c, $verb + "Async");
    def route as string init V21 + "/repos/async-batch-" + $verb + "-item/";
    def d as json.Value init api(
        $c,
        "POST",
        $route,
        batchBody($c, $repoId, $dir, $names, $toRepoId, $toDir));
    def id as string init field($d, "/task_id");
    if ($id == "") {
        fail("POST " + $route + ": the reply holds no task id");
    }
    return $id;
}

/**
 * Start copying items of one folder into a folder in the background. For
 * large trees; follow it with `taskProgress`.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the source library
 * @param dir {string} the folder the items are in
 * @param names {list of string} the items' names
 * @param toRepoId {string} the target library
 * @param toDir {string} the target folder
 * @return {string} the task id
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func copyAsync(
    c as Client,
    repoId as string,
    dir as string,
    names as list of string,
    toRepoId as string,
    toDir as string) {
    return asyncBatch($c, "copy", $repoId, $dir, $names, $toRepoId, $toDir);
}

/**
 * Start moving items of one folder into a folder in the background.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the source library
 * @param dir {string} the folder the items are in
 * @param names {list of string} the items' names
 * @param toRepoId {string} the target library
 * @param toDir {string} the target folder
 * @return {string} the task id
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func moveAsync(
    c as Client,
    repoId as string,
    dir as string,
    names as list of string,
    toRepoId as string,
    toDir as string) {
    return asyncBatch($c, "move", $repoId, $dir, $names, $toRepoId, $toDir);
}

/**
 * A task id, checked.
 *
 * @param id {string} the id
 * @return {string} the id
 */
func checkTask(id as string) {
    if (not regex.matches('^[A-Za-z0-9-]+$', $id)) {
        fail("a task id is letters, digits and -, got " + shown($id));
    }
    return $id;
}

/**
 * The state of an async copy or move.
 *
 * @param c {Client} the client
 * @param taskId {string} from `copyAsync` or `moveAsync`
 * @return {Progress} the state
 * @throws {Error} kind `"seafile"` on a bad or unknown id, or as `call`
 */
export func taskProgress(c as Client, taskId as string) {
    accountOnly($c, "taskProgress");
    def route as string init V21 + "/query-copy-move-progress/?" +
        param("task_id", checkTask($taskId));
    def d as json.Value init api($c, "GET", $route, "");
    return Progress{
        done: numberAt($d, "/done"),
        total: numberAt($d, "/total"),
        canceled: flag($d, "/canceled"),
        failed: flag($d, "/failed"),
        successful: flag($d, "/successful")
    };
}

/**
 * Cancel an async copy or move.
 *
 * @param c {Client} the client
 * @param taskId {string} from `copyAsync` or `moveAsync`
 * @throws {Error} kind `"seafile"` on a bad id, or as `call`
 */
export func cancelTask(c as Client, taskId as string) {
    accountOnly($c, "cancelTask");
    def form as string init "task_id=" + uri.encodeForm(checkTask($taskId));
    apiForm($c, "DELETE", V21 + "/copy-move-task/", $form);
}

/**
 * Delete items of one folder, files and folders alike, in one request.
 * They go to the library's trash. A name that is not there is skipped
 * without an error, as the server does.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param dir {string} the folder
 * @param names {list of string} the items' names
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func removeItems(c as Client, repoId as string, dir as string, names as list of string) {
    def id as string init repoFor($c, $repoId);
    def doc as json.Value init json.decode('{}');
    def route as string init VIA + "/batch-delete-item/";
    if (not $c.repoToken) {
        $doc = json.set($doc, "/repo_id", $id);
        $route = V21 + "/repos/batch-delete-item/";
    }
    $doc = json.set($doc, "/parent_dir", checkPath($dir));
    $doc = json.set($doc, "/dirents", json.list(checkNames($names)));
    api($c, "DELETE", $route, json.encode($doc));
}

/**
 * Delete a file or a folder with everything in it: `removeItems` with one
 * item.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file or folder; not `/`
 * @throws {Error} kind `"seafile"` on the root, or as `call`
 */
export func remove(c as Client, repoId as string, path as string) {
    checkItem($path, "removed");
    removeItems($c, $repoId, parentOf($path), [nameOf($path)]);
}

/**
 * Lock or unlock a file: the shared request.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file
 * @param operation {string} `lock` or `unlock`
 */
func setLock(c as Client, repoId as string, path as string, operation as string) {
    def route as string init itemRoute($c, $repoId, "file", checkItem($path, "locked"));
    api($c, "PUT", $route, json.encode(objectOf({"operation": $operation})));
}

/**
 * Lock a file, so others cannot change it until it is unlocked. Seafile
 * Professional only; Community Edition answers HTTP 403.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file
 * @throws {Error} kind `"seafile"` when it is missing or locked by someone
 *   else, or as `call`
 */
export func lockFile(c as Client, repoId as string, path as string) {
    setLock($c, $repoId, $path, "lock");
}

/**
 * Unlock a file. Seafile Professional only, as `lockFile`.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file
 * @throws {Error} kind `"seafile"` when it is missing or locked by someone
 *   else, or as `call`
 */
export func unlockFile(c as Client, repoId as string, path as string) {
    setLock($c, $repoId, $path, "unlock");
}

/**
 * The versions of a file, newest first, following the server's
 * `next_start_commit` (the server's default page of 50). The server ends
 * a page at a rename; the next page asks for the old path the last item
 * gives (`rev_renamed_old_path`), as the web UI does. No item cap: memory
 * is bounded by `MAX_PAGES` replies of at most the reply limit each.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the file
 * @return {list of Revision} the versions
 * @throws {Error} kind `"seafile"` when it is missing, past `MAX_PAGES`
 *   pages, or as `call`
 */
export func fileHistory(c as Client, repoId as string, path as string) {
    return historyPages($c, $repoId, $path, MAX_PAGES);
}

/**
 * `fileHistory` with a page limit. Stops at an empty cursor or at a cursor
 * and path it followed before.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the file
 * @param limit {int} the most pages followed
 * @return {list of Revision} the versions
 */
func historyPages(c as Client, repoId as string, path as string, limit as int) {
    accountOnly($c, "fileHistory");
    def base as string init repoRoute(V21, $repoId, "/file/history/?");
    def at as string init checkItem($path, "a file");
    def out as list of Revision init [];
    def next as string init "";
    def seen as map of string to bool init {};
    def pages as int init 0;
    while (true) {
        if ($pages >= $limit) {
            throw Error{
                kind: "limit",
                message: "seafile: GET " + $base + param("path", $path) + ": more than " +
                    convert.toString($limit) + " pages"
            };
        }
        def route as string init $base + param("path", $at);
        if ($next != "") {
            $route = $route + "&" + param("commit_id", $next);
        }
        def d as json.Value init api($c, "GET", $route, "");
        $pages = $pages + 1;
        def last as string init "";
        for (def p in items($d, "/data")) {
            $out[] = Revision{
                commitId: field($d, $p + "/commit_id"),
                fileId: field($d, $p + "/rev_file_id"),
                path: field($d, $p + "/path"),
                size: numberAt($d, $p + "/size"),
                ctime: timeAt($d, $p + "/ctime"),
                creator: field($d, $p + "/creator_email"),
                creatorName: field($d, $p + "/creator_name"),
                description: field($d, $p + "/description")
            };
            $last = $p;
        }
        def cursor as string init "";
        if (json.typeOf($d, "/next_start_commit") == "string") {
            $cursor = json.asString($d, "/next_start_commit");
        }
        if ($last != "" and json.typeOf($d, $last + "/rev_renamed_old_path") == "string") {
            def old as string init json.asString($d, $last + "/rev_renamed_old_path");
            if ($old != "") {
                $at = checkItem($old, "a file");
            }
        }
        def key as string init $cursor + "\n" + $at;
        if ($cursor == "" or maps.has($seen, $key)) {
            return $out;
        }
        $seen[$key] = true;
        $next = $cursor;
    }
    return $out;
}

/**
 * Restore a file to the version a commit holds; the current content
 * becomes an older version.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file
 * @param commitId {string} from `fileHistory` or a `TrashItem`
 * @throws {Error} kind `"seafile"` on a bad commit id, or as `call`
 */
export func revertFile(c as Client, repoId as string, path as string, commitId as string) {
    def body as string init json.encode(objectOf({
        "operation": "revert",
        "commit_id": checkCommit($commitId)
    }));
    api($c, "POST", itemRoute($c, $repoId, "file", checkItem($path, "reverted")), $body);
}

/**
 * Restore a folder to the state a commit holds.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the folder
 * @param commitId {string} a commit of the library, e.g. a `TrashItem`'s
 * @throws {Error} kind `"seafile"` on a bad commit id, or as `call`
 */
export func revertDir(c as Client, repoId as string, path as string, commitId as string) {
    def body as string init json.encode(objectOf({
        "operation": "revert",
        "commit_id": checkCommit($commitId)
    }));
    api($c, "POST", itemRoute($c, $repoId, "dir", checkItem($path, "reverted")), $body);
}

/**
 * The query of a share endpoint.
 *
 * @param path {string} the folder, `/` for the library
 * @param kind {string} `user` or `group`
 * @param who {string} the user id or group id; "" for none
 * @return {string} `p=..&share_type=..[&username=..|&group_id=..]`
 */
func shareQuery(path as string, kind as string, who as string) {
    def q as string init param("p", checkPath($path)) + "&share_type=" +
        checkOneOf($kind, ["user", "group"], "share kind");
    if ($who == "") {
        return $q;
    }
    return $q + "&" + shareWho($kind, $who);
}

/**
 * The parameter naming whom a share is for.
 *
 * @param kind {string} `user` or `group`
 * @param who {string} the user id or group id
 * @return {string} `username=..` or `group_id=..`
 */
func shareWho(kind as string, who as string) {
    if ($kind == "group") {
        if (not regex.matches('^[0-9]+$', $who)) {
            fail("a group id is digits, got " + shown($who));
        }
        return "group_id=" + $who;
    }
    return param("username", checkText($who, "user id"));
}

/**
 * A share from a reply of `dir/shared_items`.
 *
 * @param d {json.Value} the document
 * @param p {string} the share's pointer
 * @param repoId {string} the library
 * @param path {string} the folder
 * @return {Share} the share
 */
func shareFrom(d as json.Value, p as string, repoId as string, path as string) {
    return Share{
        kind: field($d, $p + "/share_type"),
        user: field($d, $p + "/user_info/name"),
        userName: field($d, $p + "/user_info/nickname"),
        groupId: numberAt($d, $p + "/group_info/id"),
        groupName: field($d, $p + "/group_info/name"),
        permission: field($d, $p + "/permission"),
        isAdmin: flag($d, $p + "/is_admin"),
        repoId: $repoId,
        repoName: "",
        path: $path
    };
}

/**
 * The users or groups a library or folder is shared with.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder, `/` for the whole library
 * @param kind {string} `user` or `group`
 * @return {list of Share} the shares
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func shares(c as Client, repoId as string, path as string, kind as string) {
    accountOnly($c, "shares");
    def route as string init repoRoute(
        API2,
        $repoId,
        "/dir/shared_items/?" + shareQuery($path, $kind, ""));
    def d as json.Value init api($c, "GET", $route, "");
    def out as list of Share init [];
    for (def p in items($d, "")) {
        $out[] = shareFrom($d, $p, $repoId, $path);
    }
    return $out;
}

/**
 * Share a library or folder with a user or group.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder, `/` for the whole library
 * @param kind {string} `user` or `group`
 * @param who {string} the user id (e-mail) or the group id
 * @param permission {string} one of `SHARE_PERMISSIONS` or `custom-<id>`
 * @throws {Error} kind `"seafile"` on bad input, when the server reports the
 *   share as failed (unknown user, already shared), or as `call`
 */
export func share(
    c as Client,
    repoId as string,
    path as string,
    kind as string,
    who as string,
    permission as string) {
    accountOnly($c, "share");
    def route as string init repoRoute(
        API2,
        $repoId,
        "/dir/shared_items/?" + param("p", checkPath($path)));
    def form as string init "share_type=" + checkOneOf($kind, ["user", "group"], "share kind") +
        "&" +
        shareWho($kind, $who) + "&permission=" +
        checkSharePermission($permission);
    def d as json.Value init apiForm($c, "PUT", $route, $form);
    if (json.typeOf($d, "/failed/0") != "missing") {
        fail("PUT " + $route + ": " + plain(field($d, "/failed/0/error_msg"), REASON));
    }
    if (json.typeOf($d, "/success/0") == "missing") {
        fail("PUT " + $route + ": the server shared with no one");
    }
}

/**
 * Change the permission of a share.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder, `/` for the whole library
 * @param kind {string} `user` or `group`
 * @param who {string} the user id or the group id
 * @param permission {string} one of `SHARE_PERMISSIONS` or `custom-<id>`
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func changeShare(
    c as Client,
    repoId as string,
    path as string,
    kind as string,
    who as string,
    permission as string) {
    accountOnly($c, "changeShare");
    def route as string init repoRoute(
        API2,
        $repoId,
        "/dir/shared_items/?" + shareQuery($path, $kind, $who));
    apiForm($c, "POST", $route, "permission=" + checkSharePermission($permission));
}

/**
 * End a share.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder, `/` for the whole library
 * @param kind {string} `user` or `group`
 * @param who {string} the user id or the group id
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func unshare(c as Client, repoId as string, path as string, kind as string, who as string) {
    accountOnly($c, "unshare");
    def route as string init repoRoute(
        API2,
        $repoId,
        "/dir/shared_items/?" + shareQuery($path, $kind, $who));
    api($c, "DELETE", $route, "");
}

/**
 * The folders (not whole libraries) the account shares with others.
 *
 * @param c {Client} the client, with an account token
 * @return {list of Share} the shares; `kind` is `user` or `group`
 * @throws {Error} kind `"seafile"` as `call`
 */
export func sharedFolders(c as Client) {
    accountOnly($c, "sharedFolders");
    def d as json.Value init api($c, "GET", V21 + "/shared-folders/", "");
    def out as list of Share init [];
    for (def p in items($d, "")) {
        def kind as string init field($d, $p + "/share_type");
        if ($kind == "personal") {
            $kind = "user";
        }
        $out[] = Share{
            kind: $kind,
            user: field($d, $p + "/user_email"),
            userName: field($d, $p + "/user_name"),
            groupId: numberAt($d, $p + "/group_id"),
            groupName: field($d, $p + "/group_name"),
            permission: field($d, $p + "/share_permission"),
            isAdmin: false,
            repoId: field($d, $p + "/repo_id"),
            repoName: field($d, $p + "/repo_name"),
            path: field($d, $p + "/path")
        };
    }
    return $out;
}

/**
 * The libraries other users and groups share with the account
 * (`/api2/beshared-repos/`), including group and public libraries.
 * Seafile 13.0 sends the sharer and permission only for a share with the
 * user; a group entry carries neither, and the endpoint sends no display
 * name, group or admin flag.
 *
 * @param c {Client} the client, with an account token
 * @return {list of Share} the shares; `kind` is `user`, `group` or
 *   `public`, `user` the sharer ("" for a group on 13.0), `permission`
 *   from `permission` or `user_perm` ("" when neither is sent), `path` `/`;
 *   `userName`, `groupId`, `groupName` and `isAdmin` are zero
 * @throws {Error} kind `"seafile"` as `call`
 */
export func sharedWithMe(c as Client) {
    accountOnly($c, "sharedWithMe");
    def d as json.Value init api($c, "GET", API2 + "/beshared-repos/", "");
    def out as list of Share init [];
    for (def p in items($d, "")) {
        def kind as string init field($d, $p + "/share_type");
        if ($kind == "personal") {
            $kind = "user";
        }
        def id as string init field($d, $p + "/repo_id");
        if ($id == "") {
            $id = field($d, $p + "/id");
        }
        def name as string init field($d, $p + "/repo_name");
        if ($name == "") {
            $name = field($d, $p + "/name");
        }
        def permission as string init field($d, $p + "/permission");
        if ($permission == "") {
            $permission = field($d, $p + "/user_perm");
        }
        $out[] = Share{
            kind: $kind,
            user: field($d, $p + "/user"),
            userName: "",
            groupId: 0,
            groupName: "",
            permission: $permission,
            isAdmin: false,
            repoId: $id,
            repoName: $name,
            path: "/"
        };
    }
    return $out;
}

/**
 * The account's starred libraries, folders and files.
 *
 * @param c {Client} the client, with an account token
 * @return {list of Starred} the items
 * @throws {Error} kind `"seafile"` as `call`
 */
export func starred(c as Client) {
    accountOnly($c, "starred");
    def d as json.Value init api($c, "GET", V21 + "/starred-items/", "");
    def out as list of Starred init [];
    for (def p in items($d, "/starred_item_list")) {
        $out[] = Starred{
            repoId: field($d, $p + "/repo_id"),
            repoName: field($d, $p + "/repo_name"),
            path: field($d, $p + "/path"),
            name: field($d, $p + "/obj_name"),
            isDir: flag($d, $p + "/is_dir"),
            mtime: timeAt($d, $p + "/mtime"),
            deleted: flag($d, $p + "/deleted")
        };
    }
    return $out;
}

/**
 * Star a library (`path` `/`), folder or file.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the item
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func star(c as Client, repoId as string, path as string) {
    accountOnly($c, "star");
    def body as json.Value init objectOf({
        "repo_id": checkRepoId($repoId),
        "path": checkPath($path)
    });
    api($c, "POST", V21 + "/starred-items/", json.encode($body));
}

/**
 * Unstar an item.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the item
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func unstar(c as Client, repoId as string, path as string) {
    accountOnly($c, "unstar");
    def route as string init V21 + "/starred-items/?" + param("repo_id", checkRepoId($repoId)) +
        "&" +
        param("path", checkPath($path));
    api($c, "DELETE", $route, "");
}

/**
 * A share link from a reply.
 *
 * @param d {json.Value} the document
 * @param p {string} the link's pointer; "" for the root
 * @return {ShareLink} the link
 */
func shareLinkFrom(d as json.Value, p as string) {
    return ShareLink{
        token: field($d, $p + "/token"),
        link: field($d, $p + "/link"),
        repoId: field($d, $p + "/repo_id"),
        repoName: field($d, $p + "/repo_name"),
        path: field($d, $p + "/path"),
        name: field($d, $p + "/obj_name"),
        isDir: flag($d, $p + "/is_dir"),
        viewCount: numberAt($d, $p + "/view_cnt"),
        ctime: timeAt($d, $p + "/ctime"),
        expires: timeAt($d, $p + "/expire_date"),
        isExpired: flag($d, $p + "/is_expired"),
        canEdit: flag($d, $p + "/permissions/can_edit"),
        canDownload: flag($d, $p + "/permissions/can_download"),
        canUpload: flag($d, $p + "/permissions/can_upload")
    };
}

/**
 * The share links of a list reply.
 *
 * @param d {json.Value} the document
 * @return {list of ShareLink} the links
 */
func shareLinksFrom(d as json.Value) {
    def out as list of ShareLink init [];
    for (def p in items($d, "")) {
        $out[] = shareLinkFrom($d, $p);
    }
    return $out;
}

/**
 * Add a password and an expiry to a link body.
 *
 * @param doc {json.Value} the body
 * @param password {string} "" for none
 * @param expireDays {int} 0 for none
 * @return {json.Value} the body
 */
func linkOptions(doc as json.Value, password as string, expireDays as int) {
    def out as json.Value init $doc;
    if ($expireDays < 0) {
        fail("expireDays is 0 (never) or more, got " + convert.toString($expireDays));
    }
    if ($password != "") {
        $out = json.set($out, "/password", checkText($password, "password"));
    }
    if ($expireDays > 0) {
        $out = json.set($out, "/expire_days", $expireDays);
    }
    return $out;
}

/**
 * Share a file or folder with a download link.
 *
 * @param c {Client} the client
 * @param repoId {string} the library
 * @param path {string} the file or folder
 * @param opts {ShareLinkOptions} password, expiry, permissions; the zero
 *   value for an open link that allows downloads
 * @return {ShareLink} the new link
 * @throws {Error} kind `"seafile"` on bad input, a password shorter than
 *   the server's minimum (`SHARE_LINK_PASSWORD_MIN_LENGTH`), a password or
 *   expiry with a library API token (its endpoint takes neither), or as
 *   `call`
 */
export func createShareLink(
    c as Client,
    repoId as string,
    path as string,
    opts as ShareLinkOptions) {
    def id as string init repoFor($c, $repoId);
    def doc as json.Value init json.decode('{}');
    def route as string init VIA + "/share-links/";
    if ($c.repoToken and ($opts.password != "" or $opts.expireDays != 0)) {
        fail("a library API token makes share links without password or expiry");
    }
    if (not $c.repoToken) {
        $doc = json.set($doc, "/repo_id", $id);
        $route = V21 + "/share-links/";
    }
    $doc = json.set($doc, "/path", checkPath($path));
    $doc = linkOptions($doc, $opts.password, $opts.expireDays);
    def perms as json.Value init json.decode('{}');
    $perms = json.set($perms, "/can_edit", $opts.canEdit);
    $perms = json.set($perms, "/can_download", not $opts.noDownload);
    $perms = json.set($perms, "/can_upload", $opts.canUpload);
    $doc = json.set($doc, "/permissions", $perms);
    return shareLinkFrom(api($c, "POST", $route, json.encode($doc)), "");
}

/**
 * Every download share link the account made.
 *
 * @param c {Client} the client, with an account token
 * @return {list of ShareLink} the links
 * @throws {Error} kind `"seafile"` as `call`
 */
export func shareLinks(c as Client) {
    accountOnly($c, "shareLinks");
    return shareLinksFrom(api($c, "GET", V21 + "/share-links/", ""));
}

/**
 * The account's share links of a library or of one path in it.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the file or folder; "" for every link in the library
 * @return {list of ShareLink} the links
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func shareLinksOf(c as Client, repoId as string, path as string) {
    accountOnly($c, "shareLinksOf");
    def route as string init V21 + "/share-links/?" + param("repo_id", checkRepoId($repoId));
    if ($path != "") {
        $route = $route + "&" + param("path", checkPath($path));
    }
    return shareLinksFrom(api($c, "GET", $route, ""));
}

/**
 * Delete a share link. The file stays.
 *
 * @param c {Client} the client, with an account token
 * @param token {string} the link's token
 * @throws {Error} kind `"seafile"` on a bad token, or as `call`
 */
export func deleteShareLink(c as Client, token as string) {
    accountOnly($c, "deleteShareLink");
    api($c, "DELETE", V21 + "/share-links/" + checkLinkToken($token) + "/", "");
}

/**
 * An upload link from a reply.
 *
 * @param d {json.Value} the document
 * @param p {string} the link's pointer; "" for the root
 * @return {UploadLink} the link
 */
func uploadLinkFrom(d as json.Value, p as string) {
    return UploadLink{
        token: field($d, $p + "/token"),
        link: field($d, $p + "/link"),
        repoId: field($d, $p + "/repo_id"),
        repoName: field($d, $p + "/repo_name"),
        path: field($d, $p + "/path"),
        viewCount: numberAt($d, $p + "/view_cnt"),
        ctime: timeAt($d, $p + "/ctime"),
        expires: timeAt($d, $p + "/expire_date"),
        isExpired: flag($d, $p + "/is_expired")
    };
}

/**
 * Let others upload into a folder through a link.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder
 * @param password {string} the password uploaders must give; "" for none
 * @param expireDays {int} days until it expires; 0 for never
 * @return {UploadLink} the new link
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func createUploadLink(
    c as Client,
    repoId as string,
    path as string,
    password as string,
    expireDays as int) {
    accountOnly($c, "createUploadLink");
    def id as string init checkRepoId($repoId);
    def doc as json.Value init objectOf({"repo_id": $id, "path": checkPath($path)});
    $doc = linkOptions($doc, $password, $expireDays);
    return uploadLinkFrom(api($c, "POST", V21 + "/upload-links/", json.encode($doc)), "");
}

/**
 * Every upload link the account made.
 *
 * @param c {Client} the client, with an account token
 * @return {list of UploadLink} the links
 * @throws {Error} kind `"seafile"` as `call`
 */
export func uploadLinks(c as Client) {
    accountOnly($c, "uploadLinks");
    def d as json.Value init api($c, "GET", V21 + "/upload-links/", "");
    def out as list of UploadLink init [];
    for (def p in items($d, "")) {
        $out[] = uploadLinkFrom($d, $p);
    }
    return $out;
}

/**
 * Delete an upload link. The folder and what was uploaded stay.
 *
 * @param c {Client} the client, with an account token
 * @param token {string} the link's token
 * @throws {Error} kind `"seafile"` on a bad token, or as `call`
 */
export func deleteUploadLink(c as Client, token as string) {
    accountOnly($c, "deleteUploadLink");
    api($c, "DELETE", V21 + "/upload-links/" + checkLinkToken($token) + "/", "");
}

/**
 * One page of a library's trash below a folder. The server scans the
 * library's history in steps; `more` says whether it has more to scan.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder, `/` for the whole library
 * @param scanStat {string} "" for the first page, else the `scanStat` of
 *   the page before
 * @return {TrashPage} the page
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func trash(c as Client, repoId as string, path as string, scanStat as string) {
    accountOnly($c, "trash");
    def route as string init repoRoute(V21, $repoId, "/trash/?" + param("path", checkPath($path)));
    if ($scanStat != "") {
        $route = $route + "&" + param("scan_stat", $scanStat);
    }
    def d as json.Value init api($c, "GET", $route, "");
    def page as TrashPage;
    for (def p in items($d, "/data")) {
        def parent as string init field($d, $p + "/parent_dir");
        def name as string init field($d, $p + "/obj_name");
        $page.items[] = TrashItem{
            name: $name,
            parentDir: $parent,
            path: joined($parent, $name),
            isDir: flag($d, $p + "/is_dir"),
            size: numberAt($d, $p + "/size"),
            deleted: timeAt($d, $p + "/deleted_time"),
            commitId: field($d, $p + "/commit_id"),
            objId: field($d, $p + "/obj_id")
        };
    }
    $page.more = flag($d, "/more");
    $page.scanStat = field($d, "/scan_stat");
    return $page;
}

/**
 * Everything in a library's trash below a folder, following `scanStat`.
 * Stops when the server has no more, at an empty cursor or at a cursor it
 * followed before. No item cap: memory is bounded by `MAX_PAGES` replies
 * of at most the reply limit each.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder, `/` for the whole library
 * @return {list of TrashItem} the items
 * @throws {Error} kind `"seafile"` as `call`, or past `MAX_PAGES` pages
 */
export func trashAll(c as Client, repoId as string, path as string) {
    return trashPages($c, $repoId, $path, MAX_PAGES);
}

/**
 * `trashAll` with a page limit.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param path {string} the folder
 * @param limit {int} the most pages followed
 * @return {list of TrashItem} the items
 */
func trashPages(c as Client, repoId as string, path as string, limit as int) {
    def out as list of TrashItem init [];
    def cursor as string init "";
    def seen as map of string to bool init {"": true};
    def pages as int init 0;
    while (true) {
        if ($pages >= $limit) {
            throw Error{
                kind: "limit",
                message: "seafile: GET " + V21 + "/repos/" + $repoId + "/trash/: more than " +
                    convert.toString($limit) + " pages"
            };
        }
        def page as TrashPage init trash($c, $repoId, $path, $cursor);
        $pages = $pages + 1;
        for (def item in $page.items) {
            $out[] = $item;
        }
        if (not $page.more or $page.scanStat == "" or maps.has($seen, $page.scanStat)) {
            return $out;
        }
        $seen[$page.scanStat] = true;
        $cursor = $page.scanStat;
    }
    return $out;
}

/**
 * Put items from the trash back where they were (`trash/revert-dirents`),
 * one request per commit they share.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param items {list of TrashItem} the items, e.g. from `trashAll`
 * @throws {Error} kind `"seafile"` on an empty list or bad input, when the
 *   server reports an item as failed, or as `call`
 */
export func restore(c as Client, repoId as string, items as list of TrashItem) {
    accountOnly($c, "restore");
    if (len($items) == 0) {
        fail("restore needs items");
    }
    def route as string init repoRoute(V21, $repoId, "/trash/revert-dirents/");
    def forms as map of string to string init {};
    def order as list of string init [];
    for (def item in $items) {
        def commit as string init checkCommit($item.commitId);
        def part as string init "path=" + uri.encodeForm(checkItem($item.path, "restored"));
        if (maps.has($forms, $commit)) {
            $forms[$commit] = $forms[$commit] + "&" + $part;
        } else {
            $forms[$commit] = $part;
            $order[] = $commit;
        }
    }
    for (def commit in $order) {
        def d as json.Value init apiForm(
            $c,
            "POST",
            $route,
            $forms[$commit] + "&commit_id=" + $commit);
        if (json.typeOf($d, "/failed/0") != "missing") {
            fail("POST " + $route + ": " +
                plain(
                field($d, "/failed/0/path") + ": " +
                    field($d, "/failed/0/error_msg"),
                REASON));
        }
    }
}

/**
 * Empty a library's trash: drop the history older than `keepDays`. There is
 * no undo. Library admins only, and only when the server allows users to
 * (`ENABLE_USER_CLEAN_TRASH`).
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param keepDays {int} days of history to keep; 0 for none
 * @throws {Error} kind `"seafile"` on a negative count, without permission
 *   (HTTP 403), or as `call`
 */
export func cleanTrash(c as Client, repoId as string, keepDays as int) {
    accountOnly($c, "cleanTrash");
    if ($keepDays < 0) {
        fail("keepDays is 0 or more, got " + convert.toString($keepDays));
    }
    apiForm(
        $c,
        "DELETE",
        repoRoute(V21, $repoId, "/trash/"),
        "keep_days=" + convert.toString($keepDays));
}

/**
 * An app name, checked: not empty, not `.` or `..`, no `/` or control
 * characters.
 *
 * @param name {string} the name
 * @return {string} the name, percent-encoded for a URL segment
 */
func appSegment(name as string) {
    if ($name == "" or $name == "." or $name == ".." or strings.contains($name, "/") or
        regex.matches("[\\x00-\\x1f\\x7f]", $name)) {
        fail("an app name is not empty, . or .. and holds no / or control characters, got " +
            shown($name));
    }
    return uri.encode($name);
}

/**
 * An API token from a reply.
 *
 * @param d {json.Value} the document
 * @param p {string} the token's pointer; "" for the root
 * @return {ApiToken} the token
 */
func apiTokenFrom(d as json.Value, p as string) {
    return ApiToken{
        repoId: field($d, $p + "/repo_id"),
        appName: field($d, $p + "/app_name"),
        generatedBy: field($d, $p + "/generated_by"),
        permission: field($d, $p + "/permission"),
        token: field($d, $p + "/api_token")
    };
}

/**
 * Make a library API token. Library admins only.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param appName {string} a name for it, unique in the library
 * @param permission {string} `r` or `rw`
 * @return {ApiToken} the new token
 * @throws {Error} kind `"seafile"` on bad input, a taken name, or as `call`
 */
export func createApiToken(c as Client, repoId as string, appName as string, permission as string) {
    accountOnly($c, "createApiToken");
    appSegment($appName);
    def body as json.Value init objectOf({
        "app_name": $appName,
        "permission": checkOneOf($permission, TOKEN_PERMISSIONS, "token permission")
    });
    def route as string init repoRoute(V21, $repoId, "/repo-api-tokens/");
    return apiTokenFrom(api($c, "POST", $route, json.encode($body)), "");
}

/**
 * The API tokens of a library.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @return {list of ApiToken} the tokens
 * @throws {Error} kind `"seafile"` on a bad id, or as `call`
 */
export func apiTokens(c as Client, repoId as string) {
    accountOnly($c, "apiTokens");
    def d as json.Value init api($c, "GET", repoRoute(V21, $repoId, "/repo-api-tokens/"), "");
    def out as list of ApiToken init [];
    for (def p in items($d, "/repo_api_tokens")) {
        $out[] = apiTokenFrom($d, $p);
    }
    return $out;
}

/**
 * Change the permission of a library API token.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param appName {string} the token's app name
 * @param permission {string} `r` or `rw`
 * @return {ApiToken} the changed token
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func setApiTokenPermission(
    c as Client,
    repoId as string,
    appName as string,
    permission as string) {
    accountOnly($c, "setApiTokenPermission");
    def route as string init repoRoute(
        V21,
        $repoId,
        "/repo-api-tokens/" + appSegment($appName) + "/");
    def body as json.Value init objectOf({
        "permission": checkOneOf($permission, TOKEN_PERMISSIONS, "token permission")
    });
    return apiTokenFrom(api($c, "PUT", $route, json.encode($body)), "");
}

/**
 * Revoke a library API token.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param appName {string} the token's app name
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func deleteApiToken(c as Client, repoId as string, appName as string) {
    accountOnly($c, "deleteApiToken");
    def route as string init repoRoute(
        V21,
        $repoId,
        "/repo-api-tokens/" + appSegment($appName) + "/");
    api($c, "DELETE", $route, "");
}

/**
 * Full-text search across libraries (`/api2/search/`). Seafile
 * Professional only; Community Edition answers HTTP 403 (`searchNames`
 * works there).
 *
 * @param c {Client} the client, with an account token
 * @param query {string} the words
 * @param opts {SearchOptions} filters and paging; the zero value for none
 * @return {list of SearchHit} the results
 * @throws {Error} kind `"seafile"` on bad input, on Community Edition, or as
 *   `call`
 */
export func search(c as Client, query as string, opts as SearchOptions) {
    accountOnly($c, "search");
    if ($opts.page < 0 or $opts.perPage < 0) {
        fail("a search page and page size are not negative");
    }
    def route as string init API2 + "/search/?" + param("q", checkText($query, "search query"));
    if ($opts.repoId != "") {
        $route = $route + "&search_repo=" + checkRepoId($opts.repoId);
    }
    if ($opts.path != "") {
        if ($opts.repoId == "") {
            fail("a search below a path needs a repoId");
        }
        $route = $route + "&" + param("search_path", checkPath($opts.path));
    }
    if ($opts.page > 0) {
        $route = $route + "&page=" + convert.toString($opts.page);
    }
    if ($opts.perPage > 0) {
        $route = $route + "&per_page=" + convert.toString($opts.perPage);
    }
    def d as json.Value init api($c, "GET", $route, "");
    def out as list of SearchHit init [];
    for (def p in items($d, "/results")) {
        $out[] = SearchHit{
            repoId: field($d, $p + "/repo_id"),
            repoName: field($d, $p + "/repo_name"),
            name: field($d, $p + "/name"),
            path: field($d, $p + "/fullpath"),
            isDir: flag($d, $p + "/is_dir"),
            size: numberAt($d, $p + "/size"),
            mtime: timeAt($d, $p + "/last_modified")
        };
    }
    return $out;
}

/**
 * Find files and folders in one library whose name contains a string
 * (`/api/v2.1/search-file/`). Works on Community Edition.
 *
 * @param c {Client} the client, with an account token
 * @param repoId {string} the library
 * @param query {string} part of the name
 * @return {list of Entry} the matches; `type` `file` or `dir` (the server
 *   says `folder`), `path` without a trailing `/`; `id`, `permission` and
 *   `modifier` are not reported
 * @throws {Error} kind `"seafile"` on bad input, or as `call`
 */
export func searchNames(c as Client, repoId as string, query as string) {
    accountOnly($c, "searchNames");
    def route as string init V21 + "/search-file/?" + param("repo_id", checkRepoId($repoId)) + "&" +
        param("q", checkText($query, "search query"));
    def d as json.Value init api($c, "GET", $route, "");
    def out as list of Entry init [];
    for (def p in items($d, "/data")) {
        def path as string init field($d, $p + "/path");
        def e as Entry;
        if ($path != "/" and strings.endsWith($path, "/")) {
            $path = trimSlashes($path);
        }
        $e.path = $path;
        $e.name = $path;
        if ($path != "/" and strings.contains($path, "/")) {
            $e.name = nameOf($path);
        }
        $e.type = field($d, $p + "/type");
        if ($e.type == "folder") {
            $e.type = "dir";
        }
        $e.size = numberAt($d, $p + "/size");
        $e.mtime = timeAt($d, $p + "/mtime");
        $out[] = $e;
    }
    return $out;
}

# The accessors below call `json.typeOf` with a pointer, which returns
# `missing` for a pointer that does not resolve (0.26.0; 0.25.0 threw).

/**
 * Read a node as text, whatever its type.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {string} the text; "" for absent or `null`
 */
func field(v as json.Value, ptr as string) {
    def kind as string init json.typeOf($v, $ptr);
    if ($kind == "string") {
        return json.asString($v, $ptr);
    } elseif ($kind == "int") {
        return convert.toString(json.asInt($v, $ptr));
    } elseif ($kind == "float") {
        return convert.toString(json.asFloat($v, $ptr));
    } elseif ($kind == "bool") {
        if (json.asBool($v, $ptr)) {
            return "true";
        }
        return "false";
    }
    return "";
}

/**
 * Read a node as an int: a number (truncated) or a numeric string.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} the number; 0 for absent, `null`, not numeric or outside
 *   the int range
 */
func numberAt(v as json.Value, ptr as string) {
    def kind as string init json.typeOf($v, $ptr);
    if ($kind == "int") {
        return json.asInt($v, $ptr);
    } elseif ($kind == "float") {
        try {
            return convert.toInt(json.asFloat($v, $ptr));
        } catch (e) {
            return 0;
        }
    } elseif ($kind == "string") {
        try {
            return convert.toInt(strings.trim(json.asString($v, $ptr)));
        } catch (e) {
            return 0;
        }
    }
    return 0;
}

/**
 * Read a node as an int, taking the leading digits of a string with junk
 * after them (`"22020651,"`).
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} the number; 0 when there are no leading digits
 */
func leadingInt(v as json.Value, ptr as string) {
    if (json.typeOf($v, $ptr) != "string") {
        return numberAt($v, $ptr);
    }
    def m as regex.Match init regex.find('^\s*-?[0-9]+', json.asString($v, $ptr));
    if ($m.start == -1) {
        return 0;
    }
    try {
        return convert.toInt(strings.trim($m.text));
    } catch (e) {
        return 0;
    }
    return 0;
}

/**
 * Read a time: seconds since the epoch as a number or numeric string, or an
 * ISO 8601 string with a zone.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} seconds since the epoch; 0 for absent, `null`, "" or
 *   unreadable
 */
func timeAt(v as json.Value, ptr as string) {
    def kind as string init json.typeOf($v, $ptr);
    if ($kind != "string") {
        return numberAt($v, $ptr);
    }
    def text as string init strings.trim(json.asString($v, $ptr));
    if ($text == "") {
        return 0;
    }
    if (regex.matches('^-?[0-9]+$', $text)) {
        return numberAt($v, $ptr);
    }
    try {
        return time.unix(time.fromIso($text));
    } catch (e) {
        return 0;
    }
    return 0;
}

/**
 * Read a flag: `true`, `"true"` or the number 1.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {bool} the flag; false for absent or `null`
 */
func flag(v as json.Value, ptr as string) {
    def text as string init field($v, $ptr);
    return $text == "true" or $text == "1";
}

/**
 * The pointers of a list's elements.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the list's pointer; "" for the root
 * @return {list of string} `<ptr>/0`, `<ptr>/1`, ...; empty when it is no list
 */
func items(v as json.Value, ptr as string) {
    def out as list of string init [];
    if (json.typeOf($v, $ptr) != "list") {
        return $out;
    }
    def n as int init json.length($v, $ptr);
    def i as int init 0;
    while ($i < $n) {
        $out[] = $ptr + "/" + convert.toString($i);
        $i = $i + 1;
    }
    return $out;
}
