# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Show the server version, the account's usage, its libraries, and per
 * library the file count, the bytes below the root and the number of
 * items in the trash.
 *
 *   SEAFILE_URL=https://cloud.example.com SEAFILE_TOKEN=... \
 *     jennifer run examples/usage.j
 *
 * Without SEAFILE_TOKEN, SEAFILE_USER and SEAFILE_PASSWORD log in.
 */
use io;
use os;

import "../src/seafile.j" as seafile;

if (not os.hasEnv("SEAFILE_URL")) {
    throw Error{
        kind: "usage",
        message: "set SEAFILE_URL and SEAFILE_TOKEN (or SEAFILE_USER and SEAFILE_PASSWORD)"
    };
}
def c as seafile.Client init seafile.withRetries(seafile.client(os.getEnv("SEAFILE_URL")), 2);
if (os.hasEnv("SEAFILE_TOKEN")) {
    $c = seafile.withToken($c, os.getEnv("SEAFILE_TOKEN"));
} else {
    def token as string init seafile.login(
        $c,
        os.getEnv("SEAFILE_USER"),
        os.getEnv("SEAFILE_PASSWORD"),
        "");
    $c = seafile.withToken($c, $token);
}

def info as seafile.ServerInfo init seafile.serverInfo($c);
def me as seafile.Account init seafile.account($c);
def quota as string init "unlimited";
if ($me.total >= 0) {
    $quota = io.sprintf("%d", $me.total);
}
io.printf("Seafile %s, %s: %d bytes of %s\n", $info.version, $me.email, $me.usage, $quota);

for (def lib in seafile.libraries($c, "")) {
    if ($lib.encrypted) {
        io.printf("%s|pad=24 encrypted, skipped\n", $lib.name);
        continue;
    }
    def files as int init 0;
    def size as int init 0;
    for (def e in seafile.listDir($c, $lib.id, "/", "file", true)) {
        $files = $files + 1;
        $size = $size + $e.size;
    }
    def trashed as int init len(seafile.trashAll($c, $lib.id, "/"));
    io.printf(
        "%s|pad=24 %d|pad=6|align=right files %d|pad=12|align=right bytes, %d in the trash\n",
        $lib.name,
        $files,
        $size,
        $trashed);
}
