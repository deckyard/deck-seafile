# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * White-box tests for seafile: jennifer test src/seafile_test.j
 *
 * The checking and parsing helpers are tested directly. The requests go to
 * one `httpd` server on a loopback port that answers both the API and the
 * `/seafhttp/` transfer URLs with canned replies and hands back what it
 * received. `@BASE@` in a reply body becomes the server's own URL, so a
 * link the fake hands out points back at it.
 */
use httpd;
use task;
use testing;

/** A canned reply. */
def struct Reply {
    status as int,
    contentType as string,
    body as string
};

/** One request as the fake server saw it. */
def struct Seen {
    method as string,
    path as string,
    query as string,
    auth as string,
    contentType as string,
    range as string,
    disposition as string,
    otp as string,
    body as bytes
};

/** A running fake server. */
def struct Fake {
    srv as httpd.Server,
    url as string,
    t as task of list of Seen
};

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the listening server
 * @param base {string} the server's URL, for `@BASE@`
 * @param replies {list of Reply} the replies
 * @return {list of Seen} the requests
 */
func serve(srv as httpd.Server, base as string, replies as list of Reply) {
    def seen as list of Seen init [];
    for (def r in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        $seen[] = Seen{
            method: httpd.method($req),
            path: httpd.path($req),
            query: httpd.rawQuery($req),
            auth: httpd.header($req, "Authorization"),
            contentType: httpd.header($req, "Content-Type"),
            range: httpd.header($req, "Content-Range"),
            disposition: httpd.header($req, "Content-Disposition"),
            otp: httpd.header($req, "X-SEAFILE-OTP"),
            body: httpd.body($req)
        };
        httpd.setHeader($req, "Content-Type", $r.contentType);
        httpd.respond($req, $r.status, strings.replace($r.body, "@BASE@", $base));
    }
    return $seen;
}

/**
 * Start a fake server that gives these replies.
 *
 * @param replies {list of Reply} the replies
 * @return {Fake} the server
 */
func fake(replies as list of Reply) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def base as string init "http://" + httpd.address($srv);
    def t as task of list of Seen init spawn {
        return serve($srv, $base, $replies);
    };
    return Fake{srv: $srv, url: $base, t: $t};
}

/**
 * Stop a fake server.
 *
 * @param f {Fake} the server
 * @return {list of Seen} what it received
 */
func finish(f as Fake) {
    def seen as list of Seen init task.wait($f.t);
    httpd.shutdown($f.srv);
    return $seen;
}

/**
 * A 200 reply with JSON.
 *
 * @param body {string} the JSON
 * @return {Reply} the reply
 */
func ok(body as string) {
    return Reply{status: 200, contentType: "application/json", body: $body};
}

/**
 * A refusal with Seafile's `error_msg` body.
 *
 * @param status {int} the HTTP status
 * @param message {string} the message
 * @return {Reply} the reply
 */
func refused(status as int, message as string) {
    return Reply{
        status: $status,
        contentType: "application/json",
        body: '{"error_msg":"' + $message + '"}'
    };
}

/**
 * A reply that hands out a transfer link on the fake itself.
 *
 * @param rest {string} the path after `/seafhttp/`
 * @return {Reply} the reply
 */
func linkTo(rest as string) {
    return ok('"@BASE@/seafhttp/' + $rest + '"');
}

/**
 * A client for a fake server with an account token.
 *
 * @param f {Fake} the server
 * @return {Client} the client
 */
func authed(f as Fake) {
    return withToken(client($f.url), "t0k3n");
}

/**
 * A client for a fake server with a library API token for `REPO`.
 *
 * @param f {Fake} the server
 * @return {Client} the client
 */
func viaToken(f as Fake) {
    return withRepoToken(client($f.url), REPO, "r3po");
}

/**
 * A client with a 2 s timeout, so a test that would send an extra request
 * fails instead of hanging.
 *
 * @param f {Fake} the server
 * @return {Client} the client
 */
func impatient(f as Fake) {
    return withTimeout(authed($f), 2000);
}

/**
 * A request body as text.
 *
 * @param s {Seen} the request
 * @return {string} the body
 */
func textOf(s as Seen) {
    return convert.stringFromBytes($s.body, "utf-8");
}

/**
 * A form body, decoded.
 *
 * @param s {Seen} the request
 * @return {map of string to string} the fields
 */
func formOf(s as Seen) {
    return uri.parseQuery(textOf($s));
}

/**
 * A multipart body, parsed.
 *
 * @param s {Seen} the request
 * @return {list of multipart.Part} the parts
 */
func partsOf(s as Seen) {
    return multipart.parse($s.contentType, $s.body);
}

/**
 * The message of the deck's error.
 *
 * @param e {Error} the error
 * @return {string} its message
 */
func messageOf(e as Error) {
    testing.assertEqual($e.kind, ERROR_KIND);
    return $e.message;
}

/**
 * Fail a test whose call was meant to throw.
 */
func missed() {
    throw Error{kind: "test", message: "the call did not fail"};
}

def const REPO as string init "63b94cf4-2542-464b-a66c-d89629ffaf1d";

def const OTHER as string init "10cd624f-49f1-494a-a01a-26c62ba93ffd";

def const COMMIT as string init "85c393e3bac8ef345532b2ccff22ec91ee01316f";

def const OLDER as string init "2a154f1351dea3c0d44c6577976aa59f2eb21b23";

def const FILE_INFO as string init '{"type":"file","repo_id":"63b94cf4-2542-464b-a66c-d89629ffaf1d",' +
    '"parent_dir":"/docs","obj_name":"a b.txt","obj_id":"dd3a0982f29f04079c4e365cbf5fce4c9af775c2",' +
    '"size":5,"mtime":"2026-11-06T15:22:24+00:00","is_locked":false}';

def const LINK as string init '{"username":"me@example.com","repo_id":"63b94cf4-2542-464b-a66c-' +
    'd89629ffaf1d","repo_name":"docs","path":"/docs/","obj_name":"docs","is_dir":true,"token":' +
    '"1139135e70f840c59ad8","link":"https://cloud.example.com/d/1139135e70f840c59ad8/",' +
    '"view_cnt":2,"ctime":"2024-03-14T15:03:32+08:00","expire_date":"2024-04-03T15:03:32+08:00",' +
    '"is_expired":false,"permissions":{"can_edit":false,"can_download":true,"can_upload":false}}';

func testClientUrl() {
    testing.assertEqual(client("cloud.example.com/").url, "https://cloud.example.com");
    testing.assertEqual(client("HTTPS://Cloud.Example.com/api2/").url, "https://cloud.example.com");
    testing.assertEqual(
        client("https://example.com/seafile/api/v2.1").url,
        "https://example.com/seafile");
    testing.assertEqual(client("http://localhost:8000").url, "http://localhost:8000");
    for (def bad in [
        "",
        " ",
        "a b",
        "ftp://x",
        "https://u:p@x",
        "https://x?a=1",
        "https://x:0",
        "https://x:70000",
        "https://x#y"
    ]) {
        try {
            client($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "base URL");
        }
    }
}

func testClientSettings() {
    def c as Client init withRetries(withTimeout(withInsecure(client("x")), 5000), 2);
    testing.assertTrue($c.tls.skipVerify);
    testing.assertEqual($c.timeoutMs, 5000);
    testing.assertEqual($c.retries, 2);
    testing.assertEqual(idleMs(client("x")), 30000);
    testing.assertEqual(idleMs($c), 5000);
    $c = withCaCert($c, convert.bytesFromString("PEM", "utf-8"));
    testing.assertFalse($c.tls.skipVerify);
    testing.assertEqual(withReplyLimit($c, 10).replyLimit, 10);
    def r as Client init withRepoToken($c, REPO, "abc");
    testing.assertTrue($r.repoToken);
    testing.assertEqual($r.repoId, REPO);
    def back as Client init withToken($r, "def");
    testing.assertFalse($back.repoToken);
    testing.assertEqual($back.repoId, "");
    testing.assertEqual(
        baseHeaders(withToken(client("http://127.0.0.1"), "t"))["Authorization"],
        "Bearer t");
    testing.assertEqual(
        baseHeaders(withLegacyAuth(withToken(client("http://127.0.0.1"), "t")))["Authorization"],
        "Token t");
    testing.assertFalse(maps.has(baseHeaders(client("http://127.0.0.1")), "Authorization"));
    testing.assertEqual(
        withFileServer($c, "https://Files.example.com/seafhttp").fileServer,
        "https://files.example.com:443");
    testing.assertEqual(withFileServer($c, "http://f:8082").fileServer, "http://f:8082");
    for (def bad in ["", "a b", "abc\r\nX-Evil: 1"]) {
        try {
            withToken($c, $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a token is not empty");
        }
    }
    try {
        withRepoToken($c, "../x", "abc");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a library id is a lower-case UUID");
    }
}

func testTimeoutsAndRetriesAreBounded() {
    testing.assertEqual(withRetries(client("x"), MAX_RETRIES).retries, 10);
    for (def n in [-1, MAX_RETRIES + 1]) {
        try {
            withRetries(client("x"), $n);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "seafile: retries are 0 to 10, got");
        }
    }
    try {
        withTimeout(client("x"), -1);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a timeout is 0 or more ms");
    }
}

func testInputIsChecked() {
    testing.assertEqual(checkPath("/"), "/");
    testing.assertEqual(checkPath("/docs/a b.txt"), "/docs/a b.txt");
    for (def bad in ["", "docs", "/docs/", "//a", "/a/../b", "/a/./b", "/a\nb"]) {
        try {
            checkPath($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a path");
        }
    }
    for (def bad in ["", ".", "..", "a/b", "a\tb"]) {
        try {
            checkName($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a name is not empty");
        }
    }
    for (def bad in ["", "63B94CF4-2542-464B-A66C-D89629FFAF1D", "../x", REPO + "/x"]) {
        try {
            checkRepoId($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a library id");
        }
    }
    for (def bad in ["", "../x", "ABC", "a/b"]) {
        try {
            checkLinkToken($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a link token");
        }
    }
    try {
        checkCommit("abc");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a commit id is 40 hex digits");
    }
    try {
        checkNames([]);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "at least one item");
    }
    for (def bad in ["/user", "api2/x", "/api2//x", "/api2/../x", "/api2/a b", "/api2/x?q=a#b"]) {
        try {
            ensureRoute($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "an API path");
        }
    }
    ensureRoute("/api/v2.1/repos/?type=mine");
    testing.assertEqual(parentOf("/a"), "/");
    testing.assertEqual(parentOf("/a/b/c"), "/a/b");
    testing.assertEqual(nameOf("/a/b/c"), "c");
    testing.assertEqual(joined("/", "a"), "/a");
    testing.assertEqual(joined("/a/", "b"), "/a/b");
    testing.assertEqual(joined("/a/", ""), "/a");
    testing.assertEqual(joined("/", ""), "/");
    def long as string init "/" + strings.repeat("x", 100) + convert.fromCodepoint(27);
    try {
        checkPath($long);
        missed();
    } catch (e) {
        testing.assertFalse(strings.contains(messageOf($e), convert.fromCodepoint(27)));
        testing.assertContains(messageOf($e), "...");
    }
}

func testFailureText() {
    testing.assertEqual(
        failureText(404, "Not Found", '{"error_msg":"File /x not found."}'),
        "HTTP 404: File /x not found.");
    testing.assertEqual(
        failureText(401, "Unauthorized", '{"detail":"Invalid token"}'),
        "HTTP 401: Invalid token");
    testing.assertEqual(
        failureText(400, "Bad Request", '{"non_field_errors":["Unable to login."]}'),
        "HTTP 400: Unable to login.");
    testing.assertEqual(
        failureText(400, "", '{"error": "Upload offset is invalid.\n"}'),
        "HTTP 400: Upload offset is invalid.");
    # The fileserver's own body: a raw newline inside the JSON string.
    testing.assertEqual(
        failureText(400, "Bad Request", '{"error": "Upload offset is invalid.' + "\n" + '"}'),
        "HTTP 400: Upload offset is invalid.");
    testing.assertEqual(
        failureText(520, "", '"Failed to make directory."'),
        "HTTP 520: Failed to make directory.");
    testing.assertEqual(failureText(502, "Bad Gateway", "<html>"), "HTTP 502: Bad Gateway");
    testing.assertEqual(failureText(500, "", ""), "HTTP 500");
    def said as string init failureText(
        500,
        "",
        '{"error_msg":"one\nforged ' +
            strings.repeat("x", 500) + '"}');
    testing.assertFalse(strings.contains($said, convert.fromCodepoint(10)));
    testing.assertContains($said, "one?forged");
    testing.assertTrue(len($said) < 250);
}

func testLogin() {
    def f as Fake init fake([
        ok('{"token":"24fd3c026886e3121b2ca630805ed425c272cb96"}'),
        Reply{
            status: 400,
            contentType: "application/json",
            body: '{"non_field_errors":["Unable to login with provided credentials."]}'
        },
        ok('{}')
    ]);
    def c as Client init withToken(client($f.url), "old");
    testing.assertEqual(
        login($c, "me@example.com", "pw", "123456"),
        "24fd3c026886e3121b2ca630805ed425c272cb96");
    try {
        login($c, "me@example.com", "bad", "");
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "seafile: POST /api2/auth-token/: HTTP 400: Unable to login with provided credentials.");
    }
    try {
        login($c, "me@example.com", "pw", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the reply holds no token");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "POST");
    testing.assertEqual($seen[0].path, "/api2/auth-token/");
    testing.assertEqual($seen[0].auth, "");
    testing.assertEqual($seen[0].otp, "123456");
    testing.assertEqual($seen[0].contentType, "application/json");
    def body as json.Value init json.decode(textOf($seen[0]));
    testing.assertEqual(json.asString($body, "/username"), "me@example.com");
    testing.assertEqual(json.asString($body, "/password"), "pw");
    testing.assertEqual($seen[1].otp, "");
    for (def bad in ["12ab", "1"]) {
        try {
            login($c, "me", "pw", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a two-factor code is digits");
        }
    }
}

func testCredentialsNeedHttpsOffLoopback() {
    # Port 1 on a non-loopback host that is never contacted: the guard throws
    # before any connection.
    def c as Client init withToken(client("http://cloud.example.com:1"), "t");
    try {
        account($c);
        missed();
    } catch (e) {
        testing.assertContains(
            messageOf($e),
            "credentials go over http:// only to a loopback host");
    }
    try {
        login(client("http://cloud.example.com:1"), "me", "pw", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "passwords go over http:// only to a loopback host");
    }
    testing.assertTrue(isLoopbackHost("127.0.0.1"));
    testing.assertTrue(isLoopbackHost("127.200.3.4"));
    testing.assertTrue(isLoopbackHost("localhost"));
    testing.assertTrue(isLoopbackHost("[::1]"));
    testing.assertFalse(isLoopbackHost("128.0.0.1"));
    testing.assertFalse(isLoopbackHost("localhost.example.com"));
    def headers as map of string to string init baseHeaders(withPlainHttp($c));
    testing.assertEqual($headers["Authorization"], "Bearer t");
}

func testServerInfoAndAccount() {
    def f as Fake init fake([
        ok('{"version":"13.0.29","encrypted_library_version":2,"features":["seafile-basic"]}'),
        ok('{"login_id":"","is_staff":true,"name":"Ada","email":"ada@example.com","contact_email":' +
            '"a@example.com","institution":"I","department":"D","usage":"22020651,","total":' +
            '"30000000,"}'),
        ok('{"email":"x@auth.local","usage":0,"total":-2,"is_staff":false}')
    ]);
    def c as Client init authed($f);
    def info as ServerInfo init serverInfo($c);
    testing.assertEqual($info.version, "13.0.29");
    testing.assertEqual($info.encryptedLibraryVersion, 2);
    testing.assertEqual($info.features, ["seafile-basic"]);
    def a as Account init account($c);
    testing.assertEqual($a.email, "ada@example.com");
    testing.assertEqual($a.contactEmail, "a@example.com");
    testing.assertTrue($a.isStaff);
    testing.assertEqual($a.usage, 22020651);
    testing.assertEqual($a.total, 30000000);
    def b as Account init account($c);
    testing.assertEqual($b.total, -2);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/server-info/");
    testing.assertEqual($seen[1].path, "/api2/account/info/");
    testing.assertEqual($seen[1].auth, "Bearer t0k3n");
}

func testCall() {
    def f as Fake init fake([ok('{"keep_days":-1}'), Reply{status: 204, contentType: "", body: ""}]);
    def c as Client init authed($f);
    def route as string init "/api2/repos/" + REPO + "/history-limit/";
    testing.assertEqual(json.asInt(call($c, "get", $route + "?x=1", ""), "/keep_days"), -1);
    testing.assertEqual(json.typeOf(call($c, "PUT", $route, '{"keep_days":7}')), "null");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "GET");
    testing.assertEqual($seen[0].path, $route);
    testing.assertEqual($seen[0].query, "x=1");
    testing.assertEqual($seen[1].contentType, "application/json");
    testing.assertEqual(textOf($seen[1]), '{"keep_days":7}');
    try {
        call($c, "TRACE", $route, "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "unsupported method");
    }
}

func testLibraries() {
    def lib as string init '{"type":"repo","id":"' + REPO +
        '","owner":"me@example.com","name":"docs",' +
        '"mtime":1709560091,"size":2483389,"encrypted":false,"permission":"rw"}';
    def f as Fake init fake([
        ok('[' + $lib + ']'),
        ok($lib),
        ok('{"repo_id":"' + REPO + '","repo_name":"vault","repo_size":0,"mtime":1,"encrypted":1}'),
        ok('"success"'),
        ok('"success"'),
        ok('"success"')
    ]);
    def c as Client init authed($f);
    def all as list of Library init libraries($c, "mine");
    testing.assertEqual(len($all), 1);
    testing.assertEqual($all[0].id, REPO);
    testing.assertEqual($all[0].size, 2483389);
    testing.assertEqual($all[0].mtime, 1709560091);
    testing.assertEqual($all[0].permission, "rw");
    testing.assertEqual(library($c, REPO).owner, "me@example.com");
    def made as Library init createLibrary($c, "vault", "s3cret");
    testing.assertEqual($made.id, REPO);
    testing.assertEqual($made.name, "vault");
    testing.assertTrue($made.encrypted);
    renameLibrary($c, REPO, "new name");
    decrypt($c, REPO, "s3cret");
    removeLibrary($c, REPO);
    try {
        libraries($c, "everything");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a library type is one of mine, shared, group, org");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/repos/");
    testing.assertEqual($seen[0].query, "type=mine");
    testing.assertEqual($seen[1].path, "/api2/repos/" + REPO + "/");
    testing.assertEqual($seen[2].method, "POST");
    def body as json.Value init json.decode(textOf($seen[2]));
    testing.assertEqual(json.asString($body, "/name"), "vault");
    testing.assertEqual(json.asString($body, "/passwd"), "s3cret");
    testing.assertEqual($seen[3].query, "op=rename");
    testing.assertEqual($seen[3].contentType, "application/x-www-form-urlencoded");
    testing.assertEqual(formOf($seen[3])["repo_name"], "new name");
    testing.assertEqual($seen[4].query, "");
    testing.assertEqual(formOf($seen[4])["password"], "s3cret");
    testing.assertEqual($seen[5].method, "DELETE");
}

func testCreatePlainLibrarySendsNoPassword() {
    def f as Fake init fake([ok('{"repo_id":"' + REPO + '","repo_name":"x","encrypted":""}')]);
    testing.assertFalse(createLibrary(authed($f), "x", "").encrypted);
    def seen as list of Seen init finish($f);
    testing.assertEqual(textOf($seen[0]), '{"name":"x"}');
}

func testListDir() {
    def flat as string init '{"user_perm":"rw","dirent_list":[{"type":"dir","id":"fcba","name":"a",' +
        '"mtime":1793978556,"permission":"rw","parent_dir":"/docs/","starred":true},' +
        '{"type":"file","id":"dd3a","name":"h.txt","mtime":1793978544,"permission":"r",' +
        '"parent_dir":"/docs/","size":5,"modifier_email":"me@example.com","is_locked":true}]}';
    def deep as string init '{"dirent_list":[{"type":"dir","parent_dir":"/docs/a","id":"0",' +
        '"name":"b","mtime":1},{"type":"file","name":"x y.txt","size":3}]}';
    def f as Fake init fake([ok($flat), ok($deep)]);
    def c as Client init authed($f);
    def got as list of Entry init listDir($c, REPO, "/docs", "", false);
    testing.assertEqual(len($got), 2);
    testing.assertEqual($got[0].path, "/docs/a");
    testing.assertEqual($got[0].type, "dir");
    testing.assertTrue($got[0].starred);
    testing.assertEqual($got[1].path, "/docs/h.txt");
    testing.assertEqual($got[1].size, 5);
    testing.assertEqual($got[1].mtime, 1793978544);
    testing.assertEqual($got[1].permission, "r");
    testing.assertEqual($got[1].modifier, "me@example.com");
    testing.assertTrue($got[1].isLocked);
    def all as list of Entry init listDir($c, REPO, "/docs", "file", true);
    testing.assertEqual($all[0].path, "/docs/a/b");
    testing.assertEqual($all[1].path, "/docs/x y.txt");
    testing.assertEqual($all[1].type, "file");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/dir/");
    testing.assertEqual($seen[0].query, "p=%2Fdocs");
    testing.assertEqual($seen[1].query, "p=%2Fdocs&t=f&recursive=1");
    try {
        listDir($c, REPO, "/", "files", false);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a listing type is one of file, dir");
    }
}

func testDetailsAndExists() {
    def f as Fake init fake([
        ok(FILE_INFO),
        ok('{"repo_id":"' + REPO + '","path":"/docs/","name":"docs","mtime":' +
            '"2026-11-06T15:22:36+00:00","permission":"rw"}'),
        ok(FILE_INFO),
        refused(404, "File /docs not found."),
        ok('{}'),
        refused(404, "File /nope not found."),
        refused(404, "Folder /nope/ not found."),
        refused(404, "Library not found.")
    ]);
    def c as Client init authed($f);
    def file as Entry init fileDetail($c, REPO, "/docs/a b.txt");
    testing.assertEqual($file.name, "a b.txt");
    testing.assertEqual($file.path, "/docs/a b.txt");
    testing.assertEqual($file.id, "dd3a0982f29f04079c4e365cbf5fce4c9af775c2");
    testing.assertEqual($file.mtime, 1793978544);
    def dir as Entry init dirDetail($c, REPO, "/docs");
    testing.assertEqual($dir.path, "/docs");
    testing.assertEqual($dir.type, "dir");
    testing.assertEqual($dir.mtime, 1793978556);
    testing.assertTrue(exists($c, REPO, "/docs/a b.txt"));
    testing.assertTrue(exists($c, REPO, "/docs"));
    testing.assertFalse(exists($c, REPO, "/nope"));
    try {
        exists($c, REPO, "/x");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "HTTP 404: Library not found.");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/file/");
    testing.assertEqual($seen[0].query, "p=%2Fdocs%2Fa%20b.txt");
    testing.assertEqual($seen[1].path, "/api/v2.1/repos/" + REPO + "/dir/detail/");
    testing.assertEqual($seen[1].query, "path=%2Fdocs");
    testing.assertEqual($seen[4].path, "/api/v2.1/repos/" + REPO + "/dir/detail/");
}

func testMkdir() {
    def f as Fake init fake([
        ok('{"type":"dir","parent_dir":"/","obj_name":"docs (1)","obj_id":"0","mtime":"x"}'),
        Reply{status: 201, contentType: "application/json", body: '"success"'}
    ]);
    def c as Client init authed($f);
    testing.assertEqual(mkdir($c, REPO, "/docs", false), "/docs (1)");
    testing.assertEqual(mkdir($c, REPO, "/a/b c", true), "/a/b c");
    try {
        mkdir($c, REPO, "/", true);
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "seafile: the root cannot be made");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "POST");
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/dir/");
    testing.assertEqual($seen[0].query, "p=%2Fdocs");
    testing.assertEqual(textOf($seen[0]), '{"operation":"mkdir"}');
    testing.assertEqual($seen[1].path, "/api2/repos/" + REPO + "/dir/");
    testing.assertEqual($seen[1].query, "p=%2Fa%2Fb%20c");
    testing.assertEqual(formOf($seen[1])["operation"], "mkdir");
    testing.assertEqual(formOf($seen[1])["create_parents"], "true");
}

func testMkdirParentsWithARepoToken() {
    # /a exists, /a/b does not: probe /a, probe /a/b, mkdir /a/b, mkdir /a/b/c.
    def f as Fake init fake([
        ok('{"dirent_list":[]}'),
        refused(404, "Folder /a/b/ not found."),
        ok('{"parent_dir":"/a","obj_name":"b"}'),
        ok('{"parent_dir":"/a/b","obj_name":"c"}')
    ]);
    testing.assertEqual(mkdir(withTimeout(viaToken($f), 2000), REPO, "/a/b/c", true), "/a/b/c");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/via-repo-token/dir/");
    testing.assertEqual($seen[0].query, "path=%2Fa&type=d");
    testing.assertEqual($seen[0].auth, "Bearer r3po");
    testing.assertEqual($seen[2].method, "POST");
    testing.assertEqual($seen[2].query, "path=%2Fa%2Fb");
    testing.assertEqual($seen[3].query, "path=%2Fa%2Fb%2Fc");
}

func testMkdirParentsRefusesAFileInTheWay() {
    def f as Fake init fake([
        refused(404, "Folder /a/ not found."),
        ok('{"parent_dir":"/","obj_name":"a (1)"}')
    ]);
    try {
        mkdir(withTimeout(viaToken($f), 2000), REPO, "/a/b", true);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "\"/a\" is taken by a file");
    }
    finish($f);
}

func testGet() {
    def f as Fake init fake([
        linkTo("files/0b6e-11/a%20b.txt"),
        Reply{status: 200, contentType: "application/octet-stream", body: "hello"}
    ]);
    def c as Client init authed($f);
    testing.assertEqual(
        convert.stringFromBytes(get($c, REPO, "/docs/a b.txt", 0), "utf-8"),
        "hello");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/repos/" + REPO + "/file/");
    testing.assertEqual($seen[0].query, "p=%2Fdocs%2Fa%20b.txt");
    testing.assertEqual($seen[0].auth, "Bearer t0k3n");
    testing.assertEqual($seen[1].method, "GET");
    testing.assertEqual($seen[1].path, "/seafhttp/files/0b6e-11/a b.txt");
    testing.assertEqual($seen[1].auth, "");
}

func testGetCapAndRefusals() {
    def body as Reply init Reply{
        status: 200,
        contentType: "application/octet-stream",
        body: "hello"
    };
    def f as Fake init fake([
        linkTo("files/tok-1/a"),
        $body,
        linkTo("files/tok-1/a"),
        $body,
        linkTo("files/tok-2/a"),
        $body,
        linkTo("files/tok-3/a"),
        Reply{status: 404, contentType: "application/json", body: '{"error": "File not found\n"}'}
    ]);
    def c as Client init authed($f);
    testing.assertEqual(len(get($c, REPO, "/a", -1)), 5);
    testing.assertEqual(len(get($c, REPO, "/a", 5)), 5);
    # The cap counts the body: a 5-byte file is refused at 4.
    try {
        get($c, REPO, "/a", 4);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "exceeds 4 bytes");
        testing.assertContains(messageOf($e), "GET /seafhttp/files/...");
        testing.assertFalse(strings.contains(messageOf($e), "tok-2"));
    }
    try {
        get($c, REPO, "/a", 0);
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "seafile: GET /seafhttp/files/...: HTTP 404: File not found");
    }
    finish($f);
}

func testTransferLinksAreChecked() {
    def c as Client init withToken(client("https://cloud.example.com"), "t");
    def good as string init transferLink(
        $c,
        json.decode('"https://Cloud.example.com:443/seafhttp/' +
            'files/x/a"'),
        "GET x");
    testing.assertEqual($good, "https://Cloud.example.com:443/seafhttp/files/x/a");
    for (def bad in [
        '"https://evil.example.com/seafhttp/files/x/a"',
        '"http://cloud.example.com/seafhttp/files/x/a"',
        '"https://cloud.example.com:8082/seafhttp/files/x/a"',
        '"https://user@cloud.example.com/seafhttp/files/x/a"'
    ]) {
        try {
            transferLink($c, json.decode($bad), "GET x");
            missed();
        } catch (e) {
            def said as string init messageOf($e);
            testing.assertTrue(strings.contains($said, "withFileServer allows another origin") or
                strings.contains($said, "holds no user"));
        }
    }
    try {
        transferLink($c, json.decode('{"url":"x"}'), "GET x");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "seafile: GET x: the reply is not a link");
    }
    def files as Client init withFileServer($c, "https://cloud.example.com:8082");
    testing.assertEqual(
        transferLink($files, json.decode('"https://cloud.example.com:8082/f/x"'), "GET x"),
        "https://cloud.example.com:8082/f/x");
    # A named http:// file server off loopback still needs withPlainHttp: the
    # link carries a token.
    def plain as Client init withFileServer($c, "http://files.example.com");
    try {
        transferLink($plain, json.decode('"http://files.example.com/seafhttp/files/x/a"'), "GET x");
        missed();
    } catch (e) {
        testing.assertContains(
            messageOf($e),
            "transfer links go over http:// only to a loopback host");
    }
    testing.assertEqual(
        transferLink(
            withPlainHttp($plain),
            json.decode('"http://files.example.com/seafhttp/files/x/a"'),
            "GET x"),
        "http://files.example.com/seafhttp/files/x/a");
    testing.assertEqual(
        transferName("https://h/seafhttp/upload-api/0b6e?ret-json=1"),
        "/seafhttp/upload-api/...");
    testing.assertEqual(
        transferName("https://h/sub/seafhttp/files/tok/a.txt"),
        "/sub/seafhttp/files/...");
    testing.assertEqual(transferName("https://h/other/tok"), "/other/...");
}

func testPlainHttpGuardReadsTheParsedScheme() {
    # Scheme and host in any case: the guard decides on the parsed URL.
    def plain as Client init withFileServer(
        withToken(client("https://cloud.example.com"), "t"),
        "http://files.example.com");
    for (def link in [
        '"HTTP://files.example.com/seafhttp/files/x/a"',
        '"Http://FILES.Example.COM/seafhttp/files/x/a"',
        '"hTTp://files.example.com:80/seafhttp/files/x/a"'
    ]) {
        try {
            transferLink($plain, json.decode($link), "GET x");
            missed();
        } catch (e) {
            testing.assertContains(
                messageOf($e),
                "transfer links go over http:// only to a loopback host");
        }
        transferLink(withPlainHttp($plain), json.decode($link), "GET x");
    }
    def loop as Client init withToken(client("HTTP://LocalHost:8000"), "t");
    testing.assertEqual(
        transferLink($loop, json.decode('"HTTP://localhost:8000/seafhttp/files/x/a"'), "GET x"),
        "HTTP://localhost:8000/seafhttp/files/x/a");
}

func testTransferLinksOnIpv6() {
    def c as Client init withToken(client("https://[::1]:8443"), "t");
    testing.assertEqual(
        transferLink($c, json.decode('"https://[::1]:8443/seafhttp/files/x/a"'), "GET x"),
        "https://[::1]:8443/seafhttp/files/x/a");
    def d as Client init withToken(client("https://[::1]"), "t");
    testing.assertEqual(
        transferLink($d, json.decode('"https://[::1]:443/seafhttp/files/x/a"'), "GET x"),
        "https://[::1]:443/seafhttp/files/x/a");
    testing.assertEqual(
        transferLink($d, json.decode('"https://[::1]/seafhttp/files/x/a"'), "GET x"),
        "https://[::1]/seafhttp/files/x/a");
    testing.assertEqual(
        transferLink(
            withToken(client("http://[::1]:8000"), "t"),
            json.decode('"http://[::1]:8000/seafhttp/files/x/a"'),
            "GET x"),
        "http://[::1]:8000/seafhttp/files/x/a");
    for (def bad in [
        ['"https://[::1]:8444/seafhttp/files/x/a"', $c],
        ['"https://[::1]/seafhttp/files/x/a"', $c],
        ['"https://[::2]:8443/seafhttp/files/x/a"', $c],
        ['"https://[::1]:8443/seafhttp/files/x/a"', $d]
    ]) {
        try {
            transferLink($bad[1], json.decode($bad[0]), "GET x");
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "withFileServer allows another origin");
        }
    }
}

func testGetRefusesAForeignLinkBeforeFetching() {
    # Only the API request reaches the fake; the link is refused.
    def f as Fake init fake([ok('"http://127.0.0.2:1/seafhttp/files/x/a"')]);
    try {
        get(impatient($f), REPO, "/a", 0);
        missed();
    } catch (e) {
        testing.assertContains(
            messageOf($e),
            "the server handed out a link to \"http://127.0.0.2:1\"");
    }
    finish($f);
}

func testPut() {
    def f as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("upload-api/0b6e-11"),
        ok('[{"name": "a b (1).txt", "id": "dd3a0982f29f04079c4e365cbf5fce4c9af775c2", "size": 5}]')
    ]);
    def c as Client init impatient($f);
    def data as bytes init convert.bytesFromString("hello", "utf-8");
    def e as Entry init put($c, REPO, "/docs/a b.txt", $data, false);
    testing.assertEqual($e.name, "a b (1).txt");
    testing.assertEqual($e.path, "/docs/a b (1).txt");
    testing.assertEqual($e.size, 5);
    testing.assertEqual($e.type, "file");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 3);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/file-uploaded-bytes/");
    testing.assertEqual($seen[0].query, "parent_dir=%2Fdocs&file_name=a%20b.txt");
    testing.assertEqual($seen[0].auth, "Bearer t0k3n");
    testing.assertEqual($seen[1].path, "/api2/repos/" + REPO + "/upload-link/");
    testing.assertEqual($seen[1].query, "p=%2Fdocs");
    testing.assertEqual($seen[2].method, "POST");
    testing.assertEqual($seen[2].path, "/seafhttp/upload-api/0b6e-11");
    testing.assertEqual($seen[2].query, "ret-json=1");
    testing.assertEqual($seen[2].auth, "");
    testing.assertEqual($seen[2].range, "");
    def parts as list of multipart.Part init partsOf($seen[2]);
    testing.assertEqual(len($parts), 3);
    testing.assertEqual($parts[0].name, "parent_dir");
    testing.assertEqual(multipart.text($parts[0]), "/docs");
    testing.assertEqual($parts[1].name, "replace");
    testing.assertEqual(multipart.text($parts[1]), "0");
    testing.assertEqual($parts[2].name, "file");
    testing.assertEqual($parts[2].filename, "a b.txt");
    testing.assertEqual(multipart.text($parts[2]), "hello");
}

/**
 * Assert the request that drops a temp file of `held` bytes at `path`.
 *
 * @param s {Seen} the request
 * @param link {string} the update link's path
 * @param path {string} the file
 * @param held {int} the temp file's size
 */
func assertDropped(s as Seen, link as string, path as string, held as int) {
    def at as string init convert.toString($held);
    testing.assertEqual($s.method, "POST");
    testing.assertEqual($s.path, $link);
    testing.assertEqual($s.query, "head=0000000000000000000000000000000000000000");
    testing.assertEqual($s.auth, "");
    testing.assertEqual($s.range, "bytes " + $at + "-" + $at + "/" + convert.toString($held + 1));
    testing.assertEqual(
        $s.disposition,
        "attachment; filename=\"" + uri.encode(nameOf($path)) + "\"");
    def parts as list of multipart.Part init partsOf($s);
    testing.assertEqual(len($parts), 2);
    testing.assertEqual($parts[0].name, "target_file");
    testing.assertEqual(multipart.text($parts[0]), $path);
    testing.assertEqual($parts[1].name, "file");
    testing.assertEqual($parts[1].filename, nameOf($path));
    testing.assertEqual(multipart.text($parts[1]), "x");
}

func testPutDropsAStaleTempFile() {
    # A chunked upload left 4 bytes at the path: one byte at offset 4 to the
    # update link with an unknown head makes the server drop the temp file
    # and store nothing (500). Then the upload as usual. A 400 (the temp
    # changed meanwhile) is not an error either.
    def f as Fake init fake([
        ok('{"uploadedBytes":4}'),
        linkTo("update-api/77aa"),
        Reply{status: 500, contentType: "application/json", body: '{"error": "Internal error\n"}'},
        linkTo("upload-api/0b6e-11"),
        ok('[{"name":"a b.txt","id":"x","size":5}]'),
        ok('{"uploadedBytes":7}'),
        linkTo("update-api/77ab"),
        refused(400, "Upload offset is invalid."),
        linkTo("upload-api/0b6e-12"),
        ok('[{"name":"a b.txt","id":"y","size":2}]')
    ]);
    def c as Client init impatient($f);
    testing.assertEqual(
        put($c, REPO, "/docs/a b.txt", convert.bytesFromString("hello", "utf-8"), true).size,
        5);
    testing.assertEqual(
        put($c, REPO, "/docs/a b.txt", convert.bytesFromString("hi", "utf-8"), true).size,
        2);
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 10);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/file-uploaded-bytes/");
    testing.assertEqual($seen[1].path, "/api2/repos/" + REPO + "/update-link/");
    testing.assertEqual($seen[1].query, "p=%2Fdocs");
    assertDropped($seen[2], "/seafhttp/update-api/77aa", "/docs/a b.txt", 4);
    testing.assertEqual($seen[3].path, "/api2/repos/" + REPO + "/upload-link/");
    testing.assertEqual($seen[4].path, "/seafhttp/upload-api/0b6e-11");
    testing.assertEqual($seen[4].range, "");
    testing.assertEqual(multipart.text(partsOf($seen[4])[2]), "hello");
    assertDropped($seen[7], "/seafhttp/update-api/77ab", "/docs/a b.txt", 7);
    testing.assertEqual(multipart.text(partsOf($seen[9])[2]), "hi");
}

func testPutWithARepoTokenDoesNotAsk() {
    # A library token has no file-uploaded-bytes: link and upload only.
    def f as Fake init fake([linkTo("upload-api/0b6e-11"), ok('[{"name":"a","id":"x","size":2}]')]);
    put(withTimeout(viaToken($f), 2000), REPO, "/a", convert.bytesFromString("hi", "utf-8"), true);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/via-repo-token/upload-link/");
    testing.assertEqual($seen[1].path, "/seafhttp/upload-api/0b6e-11");
}

func testPutReplace() {
    def f as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("upload-api/0b6e-11?from=api"),
        ok('[{"name":"a.txt","id":"x","size":2}]')
    ]);
    testing.assertEqual(
        put(impatient($f), REPO, "/a.txt", convert.bytesFromString("hi", "utf-8"), true).path,
        "/a.txt");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[2].query, "from=api&ret-json=1");
    testing.assertEqual(multipart.text(partsOf($seen[2])[1]), "1");
}

func testPutRefusesAReplyWithoutAName() {
    def f as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("upload-api/0b6e-11"),
        ok('{"success": true}')
    ]);
    try {
        put(impatient($f), REPO, "/a.txt", convert.bytesFromString("hi", "utf-8"), true);
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "seafile: POST /seafhttp/upload-api/...: the reply names no file");
    }
    finish($f);
}

func testUpdate() {
    def f as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("update-api/77aa"),
        Reply{
            status: 200,
            contentType: "text/plain",
            body: "c0a9084d35de69c1b860eb2743971089f556afb7"
        },
        ok('{"uploadedBytes":0}'),
        linkTo("update-api/77ab"),
        Reply{status: 200, contentType: "text/plain", body: "<html>"}
    ]);
    def c as Client init impatient($f);
    testing.assertEqual(
        update($c, REPO, "/docs/a.txt", convert.bytesFromString("v2", "utf-8")),
        "c0a9084d35de69c1b860eb2743971089f556afb7");
    try {
        update($c, REPO, "/docs/a.txt", convert.bytesFromString("v3", "utf-8"));
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the reply is not a file id");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/file-uploaded-bytes/");
    testing.assertEqual($seen[0].query, "parent_dir=%2Fdocs&file_name=a.txt");
    testing.assertEqual($seen[1].path, "/api2/repos/" + REPO + "/update-link/");
    testing.assertEqual($seen[1].query, "p=%2Fdocs");
    testing.assertEqual($seen[2].auth, "");
    testing.assertEqual($seen[2].query, "");
    testing.assertEqual($seen[2].range, "");
    def parts as list of multipart.Part init partsOf($seen[2]);
    testing.assertEqual($parts[0].name, "target_file");
    testing.assertEqual(multipart.text($parts[0]), "/docs/a.txt");
    testing.assertEqual(multipart.text($parts[1]), "v2");
}

func testUpdateDropsAStaleTempFile() {
    # The temp file is dropped through the same update link, then updated.
    def f as Fake init fake([
        ok('{"uploadedBytes":3}'),
        linkTo("update-api/77aa"),
        Reply{
            status: 500,
            contentType: "application/json",
            body: '{"error": "Failed to get head commit.\n"}'
        },
        Reply{
            status: 200,
            contentType: "text/plain",
            body: "c0a9084d35de69c1b860eb2743971089f556afb7"
        }
    ]);
    testing.assertEqual(
        update(impatient($f), REPO, "/docs/a.txt", convert.bytesFromString("v2", "utf-8")),
        "c0a9084d35de69c1b860eb2743971089f556afb7");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 4);
    assertDropped($seen[2], "/seafhttp/update-api/77aa", "/docs/a.txt", 3);
    testing.assertEqual($seen[3].path, "/seafhttp/update-api/77aa");
    testing.assertEqual($seen[3].query, "");
    testing.assertEqual($seen[3].range, "");
    testing.assertEqual(multipart.text(partsOf($seen[3])[1]), "v2");
}

func testPutResumableStartsAtTheServerOffset() {
    def data as bytes init convert.bytesFromString("abcdefghijklmnopqrstuvwxyz0123", "utf-8");
    def f as Fake init fake([
        ok('{"uploadedBytes":10}'),
        linkTo("upload-api/0b6e-11"),
        ok('{"success": true}'),
        ok('{"success": true}'),
        ok('[{"name":"big \"q\".bin","id":"x","size":30}]')
    ]);
    def e as Entry init putResumable(authed($f), REPO, "/up/big \"q\".bin", $data, 8, false, true);
    testing.assertEqual($e.path, "/up/big \"q\".bin");
    testing.assertEqual($e.size, 30);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/file-uploaded-bytes/");
    testing.assertEqual($seen[0].query, "parent_dir=%2Fup&file_name=big%20%22q%22.bin");
    testing.assertEqual($seen[2].range, "bytes 10-17/30");
    testing.assertEqual($seen[3].range, "bytes 18-25/30");
    testing.assertEqual($seen[4].range, "bytes 26-29/30");
    testing.assertEqual($seen[2].disposition, "attachment; filename=\"big%20%22q%22.bin\"");
    testing.assertEqual($seen[2].auth, "");
    testing.assertEqual(multipart.text(partsOf($seen[2])[2]), "klmnopqr");
    testing.assertEqual(multipart.text(partsOf($seen[4])[2]), "0123");
    testing.assertEqual(multipart.text(partsOf($seen[4])[0]), "/up");
}

func testPutResumablePercentEncodesTheName() {
    # The fileserver percent-decodes the header name and keys the temp file
    # by the decoded name, which `file-uploaded-bytes` takes.
    def f as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("upload-api/0b6e-11"),
        ok('[{"name":"a+b 50%.txt","id":"x","size":3}]')
    ]);
    putResumable(
        impatient($f),
        REPO,
        "/a+b 50%.txt",
        convert.bytesFromString("abc", "utf-8"),
        0,
        false,
        false);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].query, "parent_dir=%2F&file_name=a%2Bb%2050%25.txt");
    testing.assertEqual($seen[2].disposition, "attachment; filename=\"a%2Bb%2050%25.txt\"");
    testing.assertEqual($seen[2].range, "bytes 0-2/3");
}

func testPutResumableFreshStartsAtZero() {
    def f as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("upload-api/0b6e-11"),
        ok('{"success": true}'),
        ok('[{"name":"a","id":"x","size":3}]')
    ]);
    putResumable(
        impatient($f),
        REPO,
        "/a",
        convert.bytesFromString("abc", "utf-8"),
        2,
        false,
        false);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[2].range, "bytes 0-1/3");
    testing.assertEqual($seen[3].range, "bytes 2-2/3");
}

func testPutResumableFreshDropsAStaleTempFile() {
    # resume false and the server holds bytes of an earlier upload: drop
    # the temp file, then chunks from 0, so nothing stale is joined.
    def f as Fake init fake([
        ok('{"uploadedBytes":2}'),
        linkTo("update-api/77aa"),
        refused(500, "Internal error"),
        linkTo("upload-api/0b6e-11"),
        ok('{"success": true}'),
        ok('[{"name":"a","id":"x","size":4}]')
    ]);
    def e as Entry init putResumable(
        impatient($f),
        REPO,
        "/a",
        convert.bytesFromString("abcd", "utf-8"),
        2,
        true,
        false);
    testing.assertEqual($e.size, 4);
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 6);
    testing.assertEqual($seen[1].path, "/api2/repos/" + REPO + "/update-link/");
    assertDropped($seen[2], "/seafhttp/update-api/77aa", "/a", 2);
    testing.assertEqual($seen[3].path, "/api2/repos/" + REPO + "/upload-link/");
    testing.assertEqual($seen[4].range, "bytes 0-1/4");
    testing.assertEqual($seen[5].range, "bytes 2-3/4");
    testing.assertEqual(multipart.text(partsOf($seen[4])[1]), "1");
    testing.assertEqual(multipart.text(partsOf($seen[4])[2]), "ab");
    testing.assertEqual(multipart.text(partsOf($seen[5])[2]), "cd");
}

func testPutResumableFreshDropsALargerTempFile() {
    # resume false: a temp file larger than the data is dropped too.
    def f as Fake init fake([
        ok('{"uploadedBytes":99}'),
        linkTo("update-api/77aa"),
        refused(500, "Internal error"),
        linkTo("upload-api/0b6e-11"),
        ok('[{"name":"a","id":"x","size":4}]')
    ]);
    putResumable(
        impatient($f),
        REPO,
        "/a",
        convert.bytesFromString("abcd", "utf-8"),
        0,
        false,
        false);
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 5);
    assertDropped($seen[2], "/seafhttp/update-api/77aa", "/a", 99);
    testing.assertEqual($seen[2].range, "bytes 99-99/100");
    testing.assertEqual($seen[4].range, "bytes 0-3/4");
}

func testPutResumableDropsACompleteTempFile() {
    # Offset == size: the fileserver refuses every chunk, so the complete
    # temp file is dropped and the chunks start at 0.
    def f as Fake init fake([
        ok('{"uploadedBytes":4}'),
        linkTo("update-api/77aa"),
        refused(500, "Internal error"),
        linkTo("upload-api/0b6e-11"),
        ok('[{"name":"a","id":"x","size":4}]')
    ]);
    putResumable(
        impatient($f),
        REPO,
        "/a",
        convert.bytesFromString("abcd", "utf-8"),
        0,
        true,
        true);
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 5);
    assertDropped($seen[2], "/seafhttp/update-api/77aa", "/a", 4);
    testing.assertEqual($seen[4].range, "bytes 0-3/4");
    testing.assertEqual(multipart.text(partsOf($seen[4])[2]), "abcd");
}

func testPutResumableRestartsOnceAfterA400() {
    # A temp file appeared after the offset was read: read it again, drop
    # it, restart at 0. A second 400 throws.
    def f as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("upload-api/0b6e-11"),
        refused(400, "Upload offset is invalid."),
        ok('{"uploadedBytes":3}'),
        linkTo("update-api/77aa"),
        refused(500, "Internal error"),
        ok('{"success": true}'),
        ok('[{"name":"a","id":"x","size":3}]')
    ]);
    def stored as Entry init putResumable(
        impatient($f),
        REPO,
        "/a",
        convert.bytesFromString("abc", "utf-8"),
        2,
        false,
        false);
    testing.assertEqual($stored.size, 3);
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 8);
    testing.assertEqual($seen[2].range, "bytes 0-1/3");
    testing.assertEqual($seen[3].path, "/api/v2.1/repos/" + REPO + "/file-uploaded-bytes/");
    assertDropped($seen[5], "/seafhttp/update-api/77aa", "/a", 3);
    testing.assertEqual($seen[6].path, "/seafhttp/upload-api/0b6e-11");
    testing.assertEqual($seen[6].range, "bytes 0-1/3");
    testing.assertEqual($seen[7].range, "bytes 2-2/3");
    # The offset still reads 0 (e.g. a name the server normalises): no
    # drop, one retry, then the 400 is the error.
    def g as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("upload-api/0b6e-11"),
        refused(400, "Upload offset is invalid."),
        ok('{"uploadedBytes":0}'),
        refused(400, "Upload offset is invalid.")
    ]);
    try {
        putResumable(
            impatient($g),
            REPO,
            "/a",
            convert.bytesFromString("abc", "utf-8"),
            2,
            false,
            false);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "HTTP 400: Upload offset is invalid.");
    }
    testing.assertEqual(len(finish($g)), 5);
}

func testPutResumableRefusesABadOffset() {
    def f as Fake init fake([ok('{"uploadedBytes":99}')]);
    try {
        putResumable(
            impatient($f),
            REPO,
            "/a",
            convert.bytesFromString("abcd", "utf-8"),
            2,
            false,
            true);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the server holds 99 bytes of \"/a\", the data 4");
    }
    finish($f);
    try {
        putResumable(
            client("http://127.0.0.1:1"),
            REPO,
            "/a",
            convert.bytesFromString("x", "utf-8"),
            -1,
            false,
            false);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a chunk size is 0 or more");
    }
}

func testPutResumableWithARepoTokenFallsBackOn400() {
    # A library token cannot ask for the offset; a stale temp file answers
    # 400 to the chunk at 0, and the data goes through put.
    def f as Fake init fake([
        linkTo("upload-api/0b6e-11"),
        Reply{
            status: 400,
            contentType: "application/json",
            body: '{"error": "Upload offset is invalid.\n"}'
        },
        linkTo("upload-api/0b6e-12"),
        ok('[{"name":"a","id":"x","size":3}]')
    ]);
    def e as Entry init putResumable(
        withTimeout(viaToken($f), 2000),
        REPO,
        "/a",
        convert.bytesFromString("abc", "utf-8"),
        2,
        false,
        false);
    testing.assertEqual($e.size, 3);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[1].range, "bytes 0-1/3");
    testing.assertEqual($seen[2].path, "/api/v2.1/via-repo-token/upload-link/");
    testing.assertEqual($seen[3].path, "/seafhttp/upload-api/0b6e-12");
    testing.assertEqual($seen[3].range, "");
    testing.assertEqual(multipart.text(partsOf($seen[3])[2]), "abc");
}

func testPutResumableWithARepoTokenRefusesOther() {
    # Only a 400 on the first chunk falls back; a 500 or a later 400 throws.
    def f as Fake init fake([linkTo("upload-api/0b6e-11"), refused(500, "Internal error.")]);
    try {
        putResumable(
            withTimeout(viaToken($f), 2000),
            REPO,
            "/a",
            convert.bytesFromString("abc", "utf-8"),
            2,
            false,
            true);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "HTTP 500: Internal error.");
    }
    finish($f);
    def g as Fake init fake([
        linkTo("upload-api/0b6e-11"),
        ok('{"success": true}'),
        refused(400, "Upload offset is invalid.")
    ]);
    try {
        putResumable(
            withTimeout(viaToken($g), 2000),
            REPO,
            "/a",
            convert.bytesFromString("abc", "utf-8"),
            2,
            false,
            false);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "HTTP 400: Upload offset is invalid.");
    }
    finish($g);
}

func testPutResumableWithARepoTokenStartsAtZero() {
    def f as Fake init fake([
        linkTo("upload-api/0b6e-11"),
        ok('{"success": true}'),
        ok('[{"name":"a","id":"x","size":3}]')
    ]);
    putResumable(
        withTimeout(viaToken($f), 2000),
        REPO,
        "/a",
        convert.bytesFromString("abc", "utf-8"),
        2,
        false,
        true);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/via-repo-token/upload-link/");
    testing.assertEqual($seen[0].query, "path=%2F");
    testing.assertEqual($seen[1].range, "bytes 0-1/3");
    testing.assertEqual($seen[2].range, "bytes 2-2/3");
}

func testPutDropIsBestEffort() {
    # The update link is refused (upload allowed, web edit not), then the
    # drop chunk cannot connect: the upload goes ahead both times.
    def f as Fake init fake([
        ok('{"uploadedBytes":4}'),
        refused(403, "You do not have permission to access this folder."),
        linkTo("upload-api/0b6e-11"),
        ok('[{"name":"a.txt","id":"x","size":2}]'),
        ok('{"uploadedBytes":4}'),
        ok('"http://127.0.0.1:1/seafhttp/update-api/77aa"'),
        linkTo("upload-api/0b6e-12"),
        ok('[{"name":"a.txt","id":"y","size":2}]')
    ]);
    def c as Client init withFileServer(impatient($f), "http://127.0.0.1:1");
    def data as bytes init convert.bytesFromString("hi", "utf-8");
    testing.assertEqual(put($c, REPO, "/a.txt", $data, true).id, "x");
    testing.assertEqual(put($c, REPO, "/a.txt", $data, true).id, "y");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 8);
    testing.assertEqual($seen[1].path, "/api2/repos/" + REPO + "/update-link/");
    testing.assertEqual($seen[3].path, "/seafhttp/upload-api/0b6e-11");
    testing.assertEqual($seen[3].range, "");
    testing.assertEqual($seen[7].path, "/seafhttp/upload-api/0b6e-12");
}

func testDropKeepsTheLinkQuery() {
    # The fileserver reads the first `head`; a link's own query stays.
    def f as Fake init fake([
        ok('{"uploadedBytes":1}'),
        linkTo("update-api/77aa?from=api"),
        refused(500, "Internal error"),
        Reply{
            status: 200,
            contentType: "text/plain",
            body: "c0a9084d35de69c1b860eb2743971089f556afb7"
        }
    ]);
    update(impatient($f), REPO, "/a.txt", convert.bytesFromString("v2", "utf-8"));
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[2].query, "from=api&head=0000000000000000000000000000000000000000");
    testing.assertEqual($seen[2].range, "bytes 1-1/2");
    testing.assertEqual($seen[3].query, "from=api");
}

func testUploadedBytesOutOfRange() {
    # A negative or huge offset is a broken reply, not a runtime error; an
    # unreadable one counts as 0.
    def data as bytes init convert.bytesFromString("hi", "utf-8");
    for (def held in ["-1", "9223372036854775807", "9007199254740993"]) {
        def f as Fake init fake([ok('{"uploadedBytes":' + $held + '}')]);
        try {
            put(impatient($f), REPO, "/a.txt", $data, true);
            missed();
        } catch (e) {
            testing.assertContains(
                messageOf($e),
                "file-uploaded-bytes/?parent_dir=%2F&file_name=a.txt: uploadedBytes " + $held +
                    " is out of range");
        }
        finish($f);
    }
    def g as Fake init fake([ok('{"uploadedBytes":"9223372036854775807"}')]);
    try {
        update(impatient($g), REPO, "/a.txt", $data);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "is out of range");
    }
    finish($g);
    def h as Fake init fake([ok('{"uploadedBytes":-5}')]);
    try {
        putResumable(impatient($h), REPO, "/a.txt", $data, 0, false, true);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "uploadedBytes -5 is out of range");
    }
    finish($h);
    def k as Fake init fake([
        ok('{"uploadedBytes":"abc"}'),
        linkTo("upload-api/0b6e-11"),
        ok('[{"name":"a.txt","id":"x","size":2}]')
    ]);
    put(impatient($k), REPO, "/a.txt", $data, true);
    testing.assertEqual(len(finish($k)), 3);
}

func testPutSendsAQuotedNameAsOneChunk() {
    # The C fileserver keeps a multipart file name's backslash escapes: a
    # name with `"` goes as one chunk with the percent-encoded header.
    def f as Fake init fake([
        ok('{"uploadedBytes":0}'),
        linkTo("upload-api/0b6e-11"),
        ok('[{"name":"a \"q\".txt","id":"x","size":5}]')
    ]);
    def stored as Entry init put(
        impatient($f),
        REPO,
        "/d/a \"q\".txt",
        convert.bytesFromString("hello", "utf-8"),
        true);
    testing.assertEqual($stored.path, "/d/a \"q\".txt");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 3);
    testing.assertEqual($seen[0].query, "parent_dir=%2Fd&file_name=a%20%22q%22.txt");
    testing.assertEqual($seen[2].range, "bytes 0-4/5");
    testing.assertEqual($seen[2].disposition, "attachment; filename=\"a%20%22q%22.txt\"");
    testing.assertEqual(multipart.text(partsOf($seen[2])[1]), "1");
    testing.assertEqual(multipart.text(partsOf($seen[2])[2]), "hello");
    # Library token over a stale temp: no plain fallback for such a name.
    def g as Fake init fake([
        linkTo("upload-api/0b6e-11"),
        refused(400, "Upload offset is invalid.")
    ]);
    try {
        put(
            withTimeout(viaToken($g), 2000),
            REPO,
            "/q\".txt",
            convert.bytesFromString("hi", "utf-8"),
            true);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a stale temp file a library token cannot drop");
    }
    testing.assertEqual(len(finish($g)), 2);
    def none as Client init client("http://127.0.0.1:1");
    try {
        put($none, REPO, "/q\".txt", convert.bytesFromString("", "utf-8"), true);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an empty file cannot be named with \"");
    }
}

func testUploadsRefuseABackslash() {
    # The C fileserver keeps only what follows the last `\` of the name.
    def c as Client init withToken(client("http://127.0.0.1:1"), "t0k3n");
    def data as bytes init convert.bytesFromString("hi", "utf-8");
    try {
        put($c, REPO, "/d/a\\b.txt", $data, true);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an uploaded file name cannot hold \\");
    }
    try {
        putResumable($c, REPO, "/d/a\\b.txt", $data, 0, true, false);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an uploaded file name cannot hold \\");
    }
}

func testRename() {
    def f as Fake init fake([
        ok('{"type":"file","parent_dir":"/docs","obj_name":"b (1).txt"}'),
        refused(404, "File /docs/sub not found."),
        ok('{"type":"dir","parent_dir":"/docs","obj_name":"new"}'),
        refused(404, "Library not found.")
    ]);
    def c as Client init authed($f);
    testing.assertEqual(rename($c, REPO, "/docs/a.txt", "b.txt"), "/docs/b (1).txt");
    testing.assertEqual(rename($c, REPO, "/docs/sub", "new"), "/docs/new");
    try {
        rename($c, REPO, "/x", "y");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "/file/?p=%2Fx: HTTP 404: Library not found.");
    }
    for (def bad in ["", "a/b", ".."]) {
        try {
            rename($c, REPO, "/x", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a name is not empty");
        }
    }
    try {
        rename($c, REPO, "/", "x");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "seafile: the root cannot be renamed");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/file/");
    testing.assertEqual(textOf($seen[0]), '{"operation":"rename","newname":"b.txt"}');
    testing.assertEqual($seen[2].path, "/api/v2.1/repos/" + REPO + "/dir/");
    testing.assertEqual($seen[2].query, "p=%2Fdocs%2Fsub");
}

func testCopyAndMove() {
    def done as Reply init ok('{"success":true}');
    def f as Fake init fake([$done, $done, $done, $done]);
    def c as Client init authed($f);
    copy($c, REPO, "/docs/a.txt", OTHER, "/in");
    move($c, REPO, "/docs", OTHER, "/");
    copyItems($c, REPO, "/docs", ["a", "b"], REPO, "/x");
    moveItems($c, REPO, "/docs", ["a"], OTHER, "/x");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/sync-batch-copy-item/");
    def body as json.Value init json.decode(textOf($seen[0]));
    testing.assertEqual(json.asString($body, "/src_repo_id"), REPO);
    testing.assertEqual(json.asString($body, "/dst_repo_id"), OTHER);
    testing.assertEqual(json.asString($body, "/src_parent_dir"), "/docs");
    testing.assertEqual(json.asString($body, "/src_dirents/0"), "a.txt");
    testing.assertEqual(json.asString($body, "/dst_parent_dir"), "/in");
    testing.assertEqual($seen[1].path, "/api/v2.1/repos/sync-batch-move-item/");
    testing.assertEqual(json.asString(json.decode(textOf($seen[1])), "/src_parent_dir"), "/");
    testing.assertEqual(json.length(json.decode(textOf($seen[2])), "/src_dirents"), 2);
    testing.assertEqual($seen[3].path, "/api/v2.1/repos/sync-batch-move-item/");
    try {
        copy($c, REPO, "/", OTHER, "/");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "seafile: the root cannot be copied");
    }
}

func testAsyncBatch() {
    def f as Fake init fake([
        ok('{"task_id":"216533cd-96e8-40be-af83-ef7b0edbf5bb"}'),
        ok('{"task_id":"316533cd-96e8-40be-af83-ef7b0edbf5bb"}'),
        ok('{"done":1,"total":2,"canceled":false,"failed":false,"successful":false}'),
        ok('{"success":true}')
    ]);
    def c as Client init authed($f);
    def id as string init copyAsync($c, REPO, "/", ["docs"], OTHER, "/");
    testing.assertEqual($id, "216533cd-96e8-40be-af83-ef7b0edbf5bb");
    moveAsync($c, REPO, "/", ["docs"], OTHER, "/");
    def p as Progress init taskProgress($c, $id);
    testing.assertEqual($p.done, 1);
    testing.assertEqual($p.total, 2);
    testing.assertFalse($p.successful);
    cancelTask($c, $id);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/async-batch-copy-item/");
    testing.assertEqual(json.asString(json.decode(textOf($seen[0])), "/dst_repo_id"), OTHER);
    testing.assertEqual($seen[1].path, "/api/v2.1/repos/async-batch-move-item/");
    testing.assertEqual($seen[2].path, "/api/v2.1/query-copy-move-progress/");
    testing.assertEqual($seen[2].query, "task_id=216533cd-96e8-40be-af83-ef7b0edbf5bb");
    testing.assertEqual($seen[3].method, "DELETE");
    testing.assertEqual($seen[3].path, "/api/v2.1/copy-move-task/");
    testing.assertEqual(formOf($seen[3])["task_id"], $id);
    try {
        taskProgress($c, "a&b");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a task id is letters, digits and -");
    }
}

func testAsyncBatchNeedsATaskId() {
    def f as Fake init fake([ok('{}')]);
    try {
        copyAsync(authed($f), REPO, "/", ["a"], REPO, "/b");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the reply holds no task id");
    }
    finish($f);
}

func testRemove() {
    def f as Fake init fake([ok('{"success":true,"commit_id":"x"}'), ok('{"success":true}')]);
    def c as Client init authed($f);
    remove($c, REPO, "/docs/a.txt");
    removeItems($c, REPO, "/", ["a", "b c"]);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "DELETE");
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/batch-delete-item/");
    testing.assertEqual(
        textOf($seen[0]),
        '{"repo_id":"' + REPO + '","parent_dir":"/docs","dirents":["a.txt"]}');
    testing.assertEqual(json.asString(json.decode(textOf($seen[1])), "/dirents/1"), "b c");
    try {
        remove($c, REPO, "/");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "seafile: the root cannot be removed");
    }
}

func testLockAndRevert() {
    def f as Fake init fake([
        ok(FILE_INFO),
        ok(FILE_INFO),
        ok('{"success":true}'),
        ok('{"success":true}')
    ]);
    def c as Client init authed($f);
    lockFile($c, REPO, "/docs/a b.txt");
    unlockFile($c, REPO, "/docs/a b.txt");
    revertFile($c, REPO, "/docs/a b.txt", COMMIT);
    revertDir($c, REPO, "/docs", COMMIT);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "PUT");
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/file/");
    testing.assertEqual(textOf($seen[0]), '{"operation":"lock"}');
    testing.assertEqual(textOf($seen[1]), '{"operation":"unlock"}');
    testing.assertEqual($seen[2].method, "POST");
    testing.assertEqual(textOf($seen[2]), '{"operation":"revert","commit_id":"' + COMMIT + '"}');
    testing.assertEqual($seen[3].path, "/api/v2.1/repos/" + REPO + "/dir/");
    testing.assertEqual($seen[3].query, "p=%2Fdocs");
}

func testFileHistory() {
    def rev as string init '{"commit_id":"' + COMMIT + '","rev_file_id":"f1","path":"/a.txt",' +
        '"size":3,"ctime":"2026-11-06T15:22:24+00:00","creator_email":"me@example.com",' +
        '"creator_name":"Me","description":"Modified \"a.txt\""}';
    def f as Fake init fake([
        ok('{"data":[' + $rev + '],"next_start_commit":"' + OLDER + '"}'),
        ok('{"data":[' + $rev + '],"next_start_commit":false}')
    ]);
    def h as list of Revision init fileHistory(authed($f), REPO, "/a.txt");
    testing.assertEqual(len($h), 2);
    testing.assertEqual($h[0].commitId, COMMIT);
    testing.assertEqual($h[0].fileId, "f1");
    testing.assertEqual($h[0].ctime, 1793978544);
    testing.assertEqual($h[0].creator, "me@example.com");
    testing.assertEqual($h[0].description, "Modified \"a.txt\"");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/file/history/");
    testing.assertEqual($seen[0].query, "path=%2Fa.txt");
    testing.assertEqual($seen[1].query, "path=%2Fa.txt&commit_id=" + OLDER);
}

func testFileHistoryFollowsARename() {
    # Page 1 ends where the file got its current name: page 2 asks for the
    # old name at the older commit.
    def f as Fake init fake([
        ok('{"data":[{"commit_id":"' + COMMIT + '","path":"/new.txt"},{"commit_id":"' + COMMIT +
            '","path":"/new.txt","rev_renamed_old_path":"/d/old name.txt"}],' +
            '"next_start_commit":"' + OLDER + '"}'),
        ok('{"data":[{"commit_id":"' + OLDER + '","path":"/d/old name.txt",' +
            '"rev_renamed_old_path":""}],"next_start_commit":"' + COMMIT + '"}'),
        ok('{"data":[{"commit_id":"' + COMMIT + '","path":"/d/old name.txt",' +
            '"rev_renamed_old_path":null}],"next_start_commit":false}')
    ]);
    def h as list of Revision init fileHistory(impatient($f), REPO, "/new.txt");
    testing.assertEqual(len($h), 4);
    testing.assertEqual($h[2].path, "/d/old name.txt");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].query, "path=%2Fnew.txt");
    testing.assertEqual($seen[1].query, "path=%2Fd%2Fold%20name.txt&commit_id=" + OLDER);
    testing.assertEqual($seen[2].query, "path=%2Fd%2Fold%20name.txt&commit_id=" + COMMIT);
}

func testFileHistoryKeepsThePathAcrossPages() {
    # A rename to the same path changes nothing; a page without the field
    # keeps the old path the rename before it gave.
    def third as string init "3c2a7f1e9b0d4c5a6e7f8091a2b3c4d5e6f70812";
    def f as Fake init fake([
        ok('{"data":[{"commit_id":"' + COMMIT + '","path":"/a.txt",' +
            '"rev_renamed_old_path":"/a.txt"}],"next_start_commit":"' + OLDER + '"}'),
        ok('{"data":[{"commit_id":"' + OLDER + '","path":"/a.txt",' +
            '"rev_renamed_old_path":"/old.txt"}],"next_start_commit":"' + COMMIT + '"}'),
        ok('{"data":[{"commit_id":"' + COMMIT + '","path":"/old.txt"}],' +
            '"next_start_commit":"' + $third + '"}'),
        ok('{"data":[],"next_start_commit":false}')
    ]);
    testing.assertEqual(len(fileHistory(impatient($f), REPO, "/a.txt")), 3);
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 4);
    testing.assertEqual($seen[1].query, "path=%2Fa.txt&commit_id=" + OLDER);
    testing.assertEqual($seen[2].query, "path=%2Fold.txt&commit_id=" + COMMIT);
    testing.assertEqual($seen[3].query, "path=%2Fold.txt&commit_id=" + $third);
}

func testFileHistoryRefusesARenameToTheRoot() {
    def f as Fake init fake([
        ok('{"data":[{"commit_id":"' + COMMIT + '","rev_renamed_old_path":"/"}],' +
            '"next_start_commit":"' + OLDER + '"}')
    ]);
    try {
        fileHistory(impatient($f), REPO, "/a.txt");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the root cannot be a file");
    }
    finish($f);
}

func testPagingRefusesPastTheLimit() {
    def f as Fake init fake([
        ok('{"data":[],"next_start_commit":"' + OLDER + '"}'),
        ok('{"data":[],"next_start_commit":"' + COMMIT + '"}'),
        ok('{"data":[],"more":true,"scan_stat":"s1"}'),
        ok('{"data":[],"more":true,"scan_stat":"s2"}')
    ]);
    def c as Client init impatient($f);
    try {
        historyPages($c, REPO, "/a.txt", 2);
        missed();
    } catch (e) {
        testing.assertContains(
            messageOf($e),
            "GET /api/v2.1/repos/" + REPO + "/file/history/?path=%2Fa.txt: more than 2 pages");
    }
    try {
        trashPages($c, REPO, "/", 2);
        missed();
    } catch (e) {
        testing.assertContains(
            messageOf($e),
            "GET /api/v2.1/repos/" + REPO + "/trash/: more than 2 pages");
    }
    testing.assertEqual(len(finish($f)), 4);
}

func testFileHistoryStopsOnARepeatedCursor() {
    def page as string init '{"data":[],"next_start_commit":"' + OLDER + '"}';
    def f as Fake init fake([ok($page), ok($page)]);
    testing.assertEqual(len(fileHistory(impatient($f), REPO, "/a.txt")), 0);
    finish($f);
}

func testShares() {
    def f as Fake init fake([
        ok('[{"share_type":"user","user_info":{"name":"bob@auth.local","nickname":"Bob"},' +
            '"permission":"r","is_admin":false}]'),
        ok('[{"share_type":"group","group_info":{"id":1,"name":"team"},"permission":"rw"}]'),
        ok('{"failed":[],"success":[{"share_type":"user"}]}'),
        ok('{"failed":[{"email":"x","error_msg":"User x not found."}],"success":[]}'),
        ok('{"failed":[],"success":[]}'),
        ok('{"success":true}'),
        ok('{"success":true}')
    ]);
    def c as Client init authed($f);
    def users as list of Share init shares($c, REPO, "/", "user");
    testing.assertEqual($users[0].user, "bob@auth.local");
    testing.assertEqual($users[0].userName, "Bob");
    testing.assertEqual($users[0].repoId, REPO);
    def groups as list of Share init shares($c, REPO, "/docs", "group");
    testing.assertEqual($groups[0].groupId, 1);
    testing.assertEqual($groups[0].groupName, "team");
    testing.assertEqual($groups[0].path, "/docs");
    share($c, REPO, "/docs", "user", "bob@auth.local", "rw");
    try {
        share($c, REPO, "/", "user", "x", "r");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), ": User x not found.");
    }
    try {
        share($c, REPO, "/", "group", "7", "r");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the server shared with no one");
    }
    changeShare($c, REPO, "/", "group", "1", "r");
    unshare($c, REPO, "/docs", "user", "bob@auth.local");
    def seen as list of Seen init finish($f);
    def route as string init "/api2/repos/" + REPO + "/dir/shared_items/";
    testing.assertEqual($seen[0].path, $route);
    testing.assertEqual($seen[0].query, "p=%2F&share_type=user");
    testing.assertEqual($seen[1].query, "p=%2Fdocs&share_type=group");
    testing.assertEqual($seen[2].method, "PUT");
    testing.assertEqual($seen[2].query, "p=%2Fdocs");
    testing.assertEqual(
        textOf($seen[2]),
        "share_type=user&username=bob%40auth.local&permission=rw");
    testing.assertEqual(formOf($seen[4])["group_id"], "7");
    testing.assertEqual($seen[5].method, "POST");
    testing.assertEqual($seen[5].query, "p=%2F&share_type=group&group_id=1");
    testing.assertEqual(textOf($seen[5]), "permission=r");
    testing.assertEqual($seen[6].method, "DELETE");
    testing.assertEqual($seen[6].query, "p=%2Fdocs&share_type=user&username=bob%40auth.local");
    for (def bad in [["team", "group", "r"], ["bob", "user", "owner"], ["bob", "world", "r"]]) {
        try {
            share($c, REPO, "/", $bad[1], $bad[0], $bad[2]);
            missed();
        } catch (e) {
            testing.assertTrue(strings.contains(messageOf($e), "a group id is digits") or
                strings.contains(messageOf($e), "is one of"));
        }
    }
}

func testSharePermissionsAndSharedWithMe() {
    def f as Fake init fake([
        ok('{"failed":[],"success":[{"share_type":"user"}]}'),
        ok('{"success":true}'),
        ok('[{"id":"' + REPO + '","repo_id":"' + REPO + '","repo_name":"docs",' +
            '"share_type":"personal","permission":"rw","user":"bob@auth.local","group_id":0,' +
            '"group_name":null,"is_shared":false},' +
            '{"id":"' + REPO + '","name":"team docs","share_type":"group","permission":null,' +
            '"user":null,"group_id":0,"group_name":null},' +
            '{"id":"' + REPO + '","name":"old","share_type":"group","permission":null,' +
            '"user_perm":"r","owner_name":"Bob","group_id":3,"is_admin":true},' +
            '{"repo_id":"' + OTHER + '","repo_name":"pub","share_type":"public",' +
            '"permission":"r","user":"admin@auth.local"}]')
    ]);
    def c as Client init authed($f);
    share($c, REPO, "/", "user", "bob@auth.local", "cloud-edit");
    changeShare($c, REPO, "/", "group", "3", "custom-12");
    def mine as list of Share init sharedWithMe($c);
    testing.assertEqual(len($mine), 4);
    testing.assertEqual($mine[0].kind, "user");
    testing.assertEqual($mine[0].user, "bob@auth.local");
    testing.assertEqual($mine[0].permission, "rw");
    testing.assertEqual($mine[0].repoName, "docs");
    testing.assertEqual($mine[0].path, "/");
    testing.assertEqual($mine[1].kind, "group");
    testing.assertEqual($mine[1].user, "");
    testing.assertEqual($mine[1].permission, "");
    testing.assertEqual($mine[1].repoId, REPO);
    testing.assertEqual($mine[1].repoName, "team docs");
    # `user_perm` stands in for `permission`; fields 13.0 never sends stay zero.
    testing.assertEqual($mine[2].permission, "r");
    testing.assertEqual($mine[2].userName, "");
    testing.assertEqual($mine[2].groupId, 0);
    testing.assertFalse($mine[2].isAdmin);
    testing.assertEqual($mine[3].kind, "public");
    testing.assertEqual($mine[3].user, "admin@auth.local");
    testing.assertEqual($mine[3].permission, "r");
    testing.assertEqual($mine[3].repoId, OTHER);
    def seen as list of Seen init finish($f);
    testing.assertEqual(formOf($seen[0])["permission"], "cloud-edit");
    testing.assertEqual(textOf($seen[1]), "permission=custom-12");
    testing.assertEqual($seen[2].method, "GET");
    testing.assertEqual($seen[2].path, "/api2/beshared-repos/");
    for (def bad in ["custom-", "custom-x", "custom-1&x=1", "Admin", ""]) {
        try {
            changeShare($c, REPO, "/", "group", "3", $bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "or custom-<id>, got");
        }
    }
}

func testSharedFoldersAndStarred() {
    def f as Fake init fake([
        ok('[{"repo_id":"' + REPO + '","repo_name":"docs","path":"/x","folder_name":"x",' +
            '"share_type":"personal","share_permission":"rw","user_name":"Bob",' +
            '"user_email":"bob@auth.local"},{"repo_id":"' + REPO + '","path":"/y","share_type":' +
            '"group","group_id":3,"group_name":"team","share_permission":"r"}]'),
        ok('{"starred_item_list":[{"repo_id":"' + REPO + '","repo_name":"docs","is_dir":false,' +
            '"path":"/a.txt","obj_name":"a.txt","mtime":"2026-11-06T15:22:24+00:00",' +
            '"deleted":false}]}'),
        ok('{}'),
        ok('{"success":true}')
    ]);
    def c as Client init authed($f);
    def folders as list of Share init sharedFolders($c);
    testing.assertEqual($folders[0].kind, "user");
    testing.assertEqual($folders[0].user, "bob@auth.local");
    testing.assertEqual($folders[0].repoName, "docs");
    testing.assertEqual($folders[1].kind, "group");
    testing.assertEqual($folders[1].groupId, 3);
    def stars as list of Starred init starred($c);
    testing.assertEqual($stars[0].name, "a.txt");
    testing.assertEqual($stars[0].mtime, 1793978544);
    star($c, REPO, "/a.txt");
    unstar($c, REPO, "/a b.txt");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/shared-folders/");
    testing.assertEqual($seen[1].path, "/api/v2.1/starred-items/");
    testing.assertEqual(textOf($seen[2]), '{"repo_id":"' + REPO + '","path":"/a.txt"}');
    testing.assertEqual($seen[3].method, "DELETE");
    testing.assertEqual($seen[3].query, "repo_id=" + REPO + "&path=%2Fa%20b.txt");
}

func testShareLinks() {
    def f as Fake init fake([
        ok(LINK),
        ok(LINK),
        ok('[' + LINK + ']'),
        ok('[' + LINK + ']'),
        ok('[]'),
        ok('{"success":true}')
    ]);
    def c as Client init authed($f);
    def o as ShareLinkOptions;
    def l as ShareLink init createShareLink($c, REPO, "/docs", $o);
    testing.assertEqual($l.token, "1139135e70f840c59ad8");
    testing.assertEqual($l.name, "docs");
    testing.assertTrue($l.isDir);
    testing.assertEqual($l.viewCount, 2);
    testing.assertEqual($l.ctime, 1710399812);
    testing.assertEqual($l.expires, 1712127812);
    testing.assertTrue($l.canDownload);
    $o.password = "0123456789";
    $o.expireDays = 7;
    $o.noDownload = true;
    $o.canUpload = true;
    createShareLink($c, REPO, "/docs", $o);
    testing.assertEqual(len(shareLinks($c)), 1);
    testing.assertEqual(len(shareLinksOf($c, REPO, "")), 1);
    testing.assertEqual(len(shareLinksOf($c, REPO, "/docs")), 0);
    deleteShareLink($c, $l.token);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/share-links/");
    testing.assertEqual(
        textOf($seen[0]),
        '{"repo_id":"' + REPO + '","path":"/docs","permissions":' +
            '{"can_edit":false,"can_download":true,"can_upload":false}}');
    def body as json.Value init json.decode(textOf($seen[1]));
    testing.assertEqual(json.asString($body, "/password"), "0123456789");
    testing.assertEqual(json.asInt($body, "/expire_days"), 7);
    testing.assertFalse(json.asBool($body, "/permissions/can_download"));
    testing.assertTrue(json.asBool($body, "/permissions/can_upload"));
    testing.assertEqual($seen[3].query, "repo_id=" + REPO);
    testing.assertEqual($seen[4].query, "repo_id=" + REPO + "&path=%2Fdocs");
    testing.assertEqual($seen[5].method, "DELETE");
    testing.assertEqual($seen[5].path, "/api/v2.1/share-links/1139135e70f840c59ad8/");
    $o.expireDays = -1;
    try {
        createShareLink($c, REPO, "/docs", $o);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "expireDays is 0 (never) or more");
    }
}

func testUploadLinks() {
    def up as string init '{"repo_id":"' + REPO + '","repo_name":"docs","path":"/in","obj_name":' +
        '"in","view_cnt":1,"ctime":"2024-03-07T09:53:57+08:00","link":' +
        '"https://cloud.example.com/u/d/b5bbd0b8cee24af69096/","token":"b5bbd0b8cee24af69096",' +
        '"expire_date":"","is_expired":false}';
    def f as Fake init fake([ok($up), ok('[' + $up + ']'), ok('{"success":true}')]);
    def c as Client init authed($f);
    def u as UploadLink init createUploadLink($c, REPO, "/in", "", 0);
    testing.assertEqual($u.token, "b5bbd0b8cee24af69096");
    testing.assertEqual($u.expires, 0);
    testing.assertEqual($u.viewCount, 1);
    testing.assertEqual(uploadLinks($c)[0].path, "/in");
    deleteUploadLink($c, $u.token);
    def seen as list of Seen init finish($f);
    testing.assertEqual(textOf($seen[0]), '{"repo_id":"' + REPO + '","path":"/in"}');
    testing.assertEqual($seen[2].path, "/api/v2.1/upload-links/b5bbd0b8cee24af69096/");
}

func testTrash() {
    def item as string init '{"parent_dir":"/docs/","obj_name":"a.txt","deleted_time":' +
        '"2024-03-05T15:11:29+08:00","scan_stat":null,"commit_id":"' + COMMIT +
        '","is_dir":false,' +
        '"size":34707,"obj_id":"36ad"}';
    def dir as string init '{"parent_dir":"/","obj_name":"old","deleted_time":' +
        '"2024-03-05T15:11:29+08:00","commit_id":"' + OLDER + '","is_dir":true,"size":"",' +
        '"obj_id":""}';
    def f as Fake init fake([
        ok('{"data":[' + $item + '],"more":true,"scan_stat":"s1"}'),
        ok('{"data":[' + $dir + '],"more":false,"scan_stat":null}')
    ]);
    def all as list of TrashItem init trashAll(authed($f), REPO, "/");
    testing.assertEqual(len($all), 2);
    testing.assertEqual($all[0].path, "/docs/a.txt");
    testing.assertEqual($all[0].parentDir, "/docs/");
    testing.assertEqual($all[0].size, 34707);
    testing.assertEqual($all[0].deleted, 1709622689);
    testing.assertEqual($all[0].commitId, COMMIT);
    testing.assertEqual($all[1].path, "/old");
    testing.assertTrue($all[1].isDir);
    testing.assertEqual($all[1].size, 0);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/trash/");
    testing.assertEqual($seen[0].query, "path=%2F");
    testing.assertEqual($seen[1].query, "path=%2F&scan_stat=s1");
}

func testTrashAllStopsOnACursorCycle() {
    # s1, s2, s1: the third page repeats a cursor, so the walk ends after 3.
    def f as Fake init fake([
        ok('{"data":[],"more":true,"scan_stat":"s1"}'),
        ok('{"data":[],"more":true,"scan_stat":"s2"}'),
        ok('{"data":[],"more":true,"scan_stat":"s1"}')
    ]);
    testing.assertEqual(len(trashAll(impatient($f), REPO, "/")), 0);
    testing.assertEqual(len(finish($f)), 3);
}

func testTrashAllStopsWithoutACursor() {
    def f as Fake init fake([ok('{"data":[],"more":true,"scan_stat":null}')]);
    testing.assertEqual(len(trashAll(impatient($f), REPO, "/docs")), 0);
    finish($f);
}

func testRestoreGroupsByCommit() {
    def f as Fake init fake([
        ok('{"failed":[],"success":[{"path":"/a","is_dir":true}]}'),
        ok('{"failed":[{"path":"/c","error_msg":"Dirent /c not found."}],"success":[]}')
    ]);
    def a as TrashItem;
    $a.path = "/a";
    $a.commitId = COMMIT;
    def b as TrashItem init $a;
    $b.path = "/docs/b c.txt";
    def other as TrashItem init $a;
    $other.path = "/c";
    $other.commitId = OLDER;
    try {
        restore(authed($f), REPO, [$a, $other, $b]);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), ": /c: Dirent /c not found.");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/trash/revert-dirents/");
    testing.assertEqual(textOf($seen[0]), "path=%2Fa&path=%2Fdocs%2Fb+c.txt&commit_id=" + COMMIT);
    testing.assertEqual(textOf($seen[1]), "path=%2Fc&commit_id=" + OLDER);
    try {
        restore(client("http://127.0.0.1:1"), REPO, []);
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "seafile: restore needs items");
    }
}

func testCleanTrash() {
    def f as Fake init fake([ok('{"success":true}')]);
    cleanTrash(authed($f), REPO, 30);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "DELETE");
    testing.assertEqual($seen[0].path, "/api/v2.1/repos/" + REPO + "/trash/");
    testing.assertEqual(textOf($seen[0]), "keep_days=30");
    try {
        cleanTrash(client("http://127.0.0.1:1"), REPO, -1);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "keepDays is 0 or more");
    }
}

func testApiTokens() {
    def tok as string init '{"repo_id":"' + REPO + '","app_name":"backup job","generated_by":' +
        '"me@example.com","permission":"rw","api_token":"05cd0945e412a0d6e955c2fe29e84efc4825ede1"}';
    def f as Fake init fake([
        ok($tok),
        ok('{"repo_api_tokens":[' + $tok + ']}'),
        ok($tok),
        ok('{"success":true}')
    ]);
    def c as Client init authed($f);
    def t as ApiToken init createApiToken($c, REPO, "backup job", "rw");
    testing.assertEqual($t.token, "05cd0945e412a0d6e955c2fe29e84efc4825ede1");
    testing.assertEqual($t.generatedBy, "me@example.com");
    testing.assertEqual(apiTokens($c, REPO)[0].appName, "backup job");
    setApiTokenPermission($c, REPO, "backup job", "r");
    deleteApiToken($c, REPO, "backup job");
    def seen as list of Seen init finish($f);
    def route as string init "/api/v2.1/repos/" + REPO + "/repo-api-tokens/";
    testing.assertEqual($seen[0].path, $route);
    testing.assertEqual(textOf($seen[0]), '{"app_name":"backup job","permission":"rw"}');
    testing.assertEqual($seen[2].method, "PUT");
    testing.assertEqual($seen[2].path, $route + "backup job/");
    testing.assertEqual(textOf($seen[2]), '{"permission":"r"}');
    testing.assertEqual($seen[3].method, "DELETE");
    for (def bad in [["", "r"], ["a/b", "r"], ["x", "admin"], [".", "r"], ["..", "r"]]) {
        try {
            createApiToken($c, REPO, $bad[0], $bad[1]);
            missed();
        } catch (e) {
            testing.assertTrue(strings.contains(messageOf($e), "an app name") or
                strings.contains(messageOf($e), "a token permission is one of r, rw"));
        }
    }
}

func testAppNamesRefuseDotSegments() {
    # `..` would make `.../repo-api-tokens/../` the library itself behind a
    # proxy that folds dot segments.
    def c as Client init withToken(client("http://127.0.0.1:1"), "t");
    for (def name in [".", ".."]) {
        try {
            deleteApiToken($c, REPO, $name);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "an app name is not empty, . or ..");
        }
        try {
            setApiTokenPermission($c, REPO, $name, "r");
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "an app name is not empty, . or ..");
        }
    }
    testing.assertEqual(appSegment("..."), "...");
    testing.assertEqual(appSegment(".x"), ".x");
}

func testRepoTokenRoutes() {
    def f as Fake init fake([
        ok('{"repo_id":"' + REPO + '","repo_name":"docs"}'),
        ok('{"dirent_list":[{"type":"file","name":"a","parent_dir":"/x/","size":1}]}'),
        ok(FILE_INFO),
        linkTo("files/tok/a"),
        Reply{status: 200, contentType: "application/octet-stream", body: "a"},
        ok('{"type":"file","parent_dir":"/x","obj_name":"b"}'),
        ok('{"success":true}'),
        ok('{"success":true}'),
        ok(LINK)
    ]);
    def c as Client init viaToken($f);
    def lib as Library init tokenLibrary($c);
    testing.assertEqual($lib.id, REPO);
    testing.assertEqual($lib.name, "docs");
    testing.assertEqual(listDir($c, REPO, "/x", "file", true)[0].path, "/x/a");
    testing.assertEqual(fileDetail($c, "", "/x/a").name, "a b.txt");
    testing.assertEqual(len(get($c, REPO, "/x/a", 0)), 1);
    testing.assertEqual(rename($c, REPO, "/x/a", "b"), "/x/b");
    move($c, REPO, "/x/b", REPO, "/y");
    remove($c, REPO, "/y/b");
    def o as ShareLinkOptions;
    createShareLink($c, REPO, "/y", $o);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api/v2.1/via-repo-token/repo-info/");
    testing.assertEqual($seen[0].auth, "Bearer r3po");
    testing.assertEqual($seen[1].path, "/api/v2.1/via-repo-token/dir/");
    testing.assertEqual($seen[1].query, "path=%2Fx&type=f&recursive=1");
    testing.assertEqual($seen[2].path, "/api/v2.1/via-repo-token/file/");
    testing.assertEqual($seen[2].query, "path=%2Fx%2Fa");
    testing.assertEqual($seen[3].path, "/api/v2.1/via-repo-token/download-link/");
    testing.assertEqual($seen[4].auth, "");
    testing.assertEqual($seen[5].path, "/api/v2.1/via-repo-token/file/");
    testing.assertEqual($seen[6].path, "/api/v2.1/via-repo-token/sync-batch-move-item/");
    testing.assertEqual(
        textOf($seen[6]),
        '{"src_parent_dir":"/x","src_dirents":["b"],"dst_parent_dir":"/y"}');
    testing.assertEqual($seen[7].path, "/api/v2.1/via-repo-token/batch-delete-item/");
    testing.assertEqual(textOf($seen[7]), '{"parent_dir":"/y","dirents":["b"]}');
    testing.assertEqual($seen[8].path, "/api/v2.1/via-repo-token/share-links/");
    testing.assertEqual(
        textOf($seen[8]),
        '{"path":"/y","permissions":{"can_edit":false,' +
            '"can_download":true,"can_upload":false}}');
}

func testRepoTokenRefusesOtherVerbsBeforeSending() {
    # Port 1: a request that is sent fails with another message.
    def c as Client init withRepoToken(client("http://127.0.0.1:1"), REPO, "r3po");
    try {
        listDir($c, OTHER, "/", "", false);
        missed();
    } catch (e) {
        testing.assertContains(
            messageOf($e),
            "this client's library API token is for library " +
                REPO + ", not " + OTHER);
    }
    try {
        copy($c, REPO, "/a", OTHER, "/");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "is for library");
    }
    def o as ShareLinkOptions;
    $o.expireDays = 3;
    try {
        createShareLink($c, REPO, "/a", $o);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "without password or expiry");
    }
    try {
        tokenLibrary(client("http://127.0.0.1:1"));
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "tokenLibrary needs a library API token");
    }
    def s as SearchOptions;
    for (def verb in [
        "account",
        "libraries",
        "dirDetail",
        "update",
        "fileHistory",
        "shares",
        "trash",
        "restore",
        "createApiToken",
        "search",
        "searchNames",
        "starred",
        "shareLinks",
        "copyAsync",
        "taskProgress",
        "cleanTrash",
        "createUploadLink"
    ]) {
        try {
            if ($verb == "account") {
                account($c);
            } elseif ($verb == "libraries") {
                libraries($c, "");
            } elseif ($verb == "dirDetail") {
                dirDetail($c, REPO, "/");
            } elseif ($verb == "update") {
                update($c, REPO, "/a", convert.bytesFromString("x", "utf-8"));
            } elseif ($verb == "fileHistory") {
                fileHistory($c, REPO, "/a");
            } elseif ($verb == "shares") {
                shares($c, REPO, "/", "user");
            } elseif ($verb == "trash") {
                trash($c, REPO, "/", "");
            } elseif ($verb == "restore") {
                restore($c, REPO, []);
            } elseif ($verb == "createApiToken") {
                createApiToken($c, REPO, "x", "r");
            } elseif ($verb == "search") {
                search($c, "x", $s);
            } elseif ($verb == "searchNames") {
                searchNames($c, REPO, "x");
            } elseif ($verb == "starred") {
                starred($c);
            } elseif ($verb == "shareLinks") {
                shareLinks($c);
            } elseif ($verb == "copyAsync") {
                copyAsync($c, REPO, "/", ["a"], REPO, "/b");
            } elseif ($verb == "taskProgress") {
                taskProgress($c, "x");
            } elseif ($verb == "cleanTrash") {
                cleanTrash($c, REPO, 0);
            } else {
                createUploadLink($c, REPO, "/", "", 0);
            }
            missed();
        } catch (e) {
            testing.assertContains(
                messageOf($e),
                "needs an account token, not a library API token");
        }
    }
}

func testSearch() {
    def f as Fake init fake([
        ok('{"has_more":false,"total":1,"results":[{"repo_id":"' + REPO + '","repo_name":"docs",' +
            '"name":"3a","fullpath":"/t/3a","is_dir":false,"size":7,"last_modified":1520836447}]}'),
        ok('{"data":[{"path":"/t/a b","size":0,"mtime":"2024-03-07T13:37:40+08:00",' +
            '"type":"folder"},{"path":"/t/c/","size":0,"mtime":0,"type":"folder"},' +
            '{"path":"/t/a.txt","size":4,"mtime":0,"type":"file"}]}')
    ]);
    def c as Client init authed($f);
    def o as SearchOptions;
    $o.repoId = REPO;
    $o.path = "/t";
    $o.page = 2;
    $o.perPage = 10;
    def hits as list of SearchHit init search($c, "3a b", $o);
    testing.assertEqual($hits[0].path, "/t/3a");
    testing.assertEqual($hits[0].mtime, 1520836447);
    testing.assertEqual($hits[0].size, 7);
    def names as list of Entry init searchNames($c, REPO, "a b");
    testing.assertEqual($names[0].name, "a b");
    testing.assertEqual($names[0].path, "/t/a b");
    testing.assertEqual($names[0].type, "dir");
    testing.assertEqual($names[0].mtime, 1709789860);
    testing.assertEqual($names[1].path, "/t/c");
    testing.assertEqual($names[1].name, "c");
    testing.assertEqual($names[1].type, "dir");
    testing.assertEqual($names[2].type, "file");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].path, "/api2/search/");
    testing.assertEqual(
        $seen[0].query,
        "q=3a%20b&search_repo=" + REPO + "&search_path=%2Ft&page=2&per_page=10");
    testing.assertEqual($seen[1].path, "/api/v2.1/search-file/");
    testing.assertEqual($seen[1].query, "repo_id=" + REPO + "&q=a%20b");
    def bad as SearchOptions;
    $bad.path = "/t";
    try {
        search($c, "x", $bad);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a search below a path needs a repoId");
    }
    $bad.path = "";
    $bad.page = -1;
    try {
        search($c, "x", $bad);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "not negative");
    }
}

func testRetriesOnlyForGet() {
    def busy as Reply init Reply{status: 503, contentType: "text/plain", body: ""};
    def f as Fake init fake([$busy, ok('{"version":"13.0"}'), $busy, linkTo("files/t/a"), $busy]);
    def c as Client init withRetries(authed($f), 1);
    testing.assertEqual(serverInfo($c).version, "13.0");
    try {
        call($c, "POST", "/api2/repos/", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "POST /api2/repos/: HTTP 503");
    }
    try {
        get($c, REPO, "/a", 0);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "GET /seafhttp/files/...: HTTP 503");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 5);
    testing.assertEqual($seen[2].method, "POST");
    testing.assertEqual($seen[4].path, "/seafhttp/files/t/a");
}

func testReplyLimit() {
    def f as Fake init fake([ok('[' + strings.repeat('{"id":"x"},', 50) + '{"id":"y"}]')]);
    try {
        libraries(withReplyLimit(authed($f), 300), "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "exceeds 300 bytes");
    }
    finish($f);
}

func testRefusalsNameTheRequest() {
    def f as Fake init fake([
        refused(404, "File /missing not found."),
        Reply{status: 200, contentType: "text/html", body: "<html>"}
    ]);
    def c as Client init authed($f);
    try {
        fileDetail($c, REPO, "/missing");
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "seafile: GET /api/v2.1/repos/" + REPO +
                "/file/?p=%2Fmissing: HTTP 404: File /missing not found.");
    }
    try {
        account($c);
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "seafile: GET /api2/account/info/: the reply is not JSON");
    }
    finish($f);
}

func testAccessorsTolerateOddValues() {
    def d as json.Value init json.decode('{"a":"12","b":3.9,"c":null,"d":"x","e":1,' +
        '"f":"2024-03-05T15:11:29+08:00","g":"1709622689","h":"","i":"-2 bytes","j":"true",' +
        '"k":1e300,"l":[1,2]}');
    testing.assertEqual(numberAt($d, "/a"), 12);
    testing.assertEqual(numberAt($d, "/b"), 3);
    testing.assertEqual(numberAt($d, "/c"), 0);
    testing.assertEqual(numberAt($d, "/d"), 0);
    testing.assertEqual(numberAt($d, "/k"), 0);
    testing.assertEqual(numberAt($d, "/nope"), 0);
    testing.assertEqual(leadingInt($d, "/i"), -2);
    testing.assertEqual(leadingInt($d, "/d"), 0);
    testing.assertEqual(leadingInt($d, "/e"), 1);
    testing.assertEqual(timeAt($d, "/f"), 1709622689);
    testing.assertEqual(timeAt($d, "/g"), 1709622689);
    testing.assertEqual(timeAt($d, "/e"), 1);
    testing.assertEqual(timeAt($d, "/h"), 0);
    testing.assertEqual(timeAt($d, "/d"), 0);
    testing.assertTrue(flag($d, "/e"));
    testing.assertTrue(flag($d, "/j"));
    testing.assertFalse(flag($d, "/c"));
    testing.assertEqual(field($d, "/b"), "3.9");
    testing.assertEqual(len(items($d, "/l")), 2);
    testing.assertEqual(len(items($d, "/a")), 0);
}
