# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Upload a local file in chunks into a dated folder of one library with a
 * library API token, and keep the newest dated folders only. Each run
 * starts fresh (`resume` false): a library API token cannot ask for the
 * offset, and a temp file left by an interrupted run is bypassed through
 * `put`, one POST of the whole file.
 *
 *   SEAFILE_URL=https://cloud.example.com SEAFILE_REPO=<library id> \
 *     SEAFILE_REPO_TOKEN=... jennifer run examples/backup.j db.sql 7
 *
 * The token comes from the library's "API Token" dialog (or
 * `createApiToken`) with `rw` permission. The second argument is how many
 * folders of `/backups` to keep, newest name first, at least 1.
 */
use convert;
use fs;
use io;
use lists;
use os;
use path;
use time;

import "../src/seafile.j" as seafile;

if (len(os.ARGS) != 3) {
    throw Error{kind: "usage", message: "usage: backup.j <file> <folders to keep>"};
}
if (not os.hasEnv("SEAFILE_URL") or not os.hasEnv("SEAFILE_REPO") or
    not os.hasEnv("SEAFILE_REPO_TOKEN")) {
    throw Error{kind: "usage", message: "set SEAFILE_URL, SEAFILE_REPO and SEAFILE_REPO_TOKEN"};
}
def repo as string init os.getEnv("SEAFILE_REPO");
def c as seafile.Client init seafile.withRepoToken(
    seafile.client(os.getEnv("SEAFILE_URL")),
    $repo,
    os.getEnv("SEAFILE_REPO_TOKEN"));
$c = seafile.withRetries($c, 2);
def keep as int init convert.toInt(os.ARGS[2]);
if ($keep < 1) {
    throw Error{kind: "usage", message: "folders to keep must be at least 1"};
}

def day as string init time.format(time.now(), "%Y-%m-%d");
def folder as string init seafile.mkdir($c, $repo, "/backups/" + $day, true);
def target as string init $folder + "/" + path.base(os.ARGS[1]);
def e as seafile.Entry init seafile.putResumable(
    $c,
    $repo,
    $target,
    fs.readBytes(os.ARGS[1]),
    0,
    true,
    false);
io.printf("stored %s, %d bytes\n", $e.path, $e.size);

def names as list of string init [];
for (def d in seafile.listDir($c, $repo, "/backups", "dir", false)) {
    $names[] = $d.name;
}
$names = lists.sort($names);
if (len($names) > $keep) {
    def old as list of string init lists.slice($names, 0, len($names) - $keep);
    seafile.removeItems($c, $repo, "/backups", $old);
    io.printf("removed %d old folders\n", len($old));
}
