# @deckyard/seafile

[![test](https://github.com/deckyard/deck-seafile/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-seafile/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-seafile/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-seafile)](https://github.com/deckyard/deck-seafile/releases/latest)

A client for the Web API of a self-hosted [Seafile](https://www.seafile.com/)
server, for [Jennifer](https://jennifer-lang.dev/) programs: libraries
(incl. encrypted), files and folders (list, download, upload, resumable
upload, rename, copy and move across libraries, history, revert), user and
group shares, libraries shared with the account, starred items, share and
upload links, the trash, library API tokens and search. `call` reaches any other endpoint.

Plain file sync can use the interpreter's `webdav` module against
`/seafdav`; this deck covers what WebDAV cannot.

**[Documentation](https://deckyard.github.io/deck-seafile/)**

## Install

```sh
jvc add @deckyard/seafile
```

This vendors the deck to `vendor/<scope>/seafile/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-seafile-<version>.tar.gz`) there.

## Usage

```jennifer
use fs;
use io;
use os;
import "@deckyard/seafile/" as seafile;

def c as seafile.Client init seafile.client("https://cloud.example.com");
$c = seafile.withToken($c, seafile.login($c, "me@example.com", os.getEnv("SEAFILE_PASSWORD"), ""));
def lib as seafile.Library init seafile.createLibrary($c, "backups", "");

seafile.mkdir($c, $lib.id, "/2026/11", true);
def e as seafile.Entry init seafile.put($c, $lib.id, "/2026/11/db.sql", fs.readBytes("db.sql"), true);
def o as seafile.ShareLinkOptions;
$o.expireDays = 7;
io.printf("%s\n", seafile.createShareLink($c, $lib.id, $e.path, $o).link);
```

Download and upload a file, no WebDAV needed:

```jennifer
def data as bytes init seafile.get($c, $lib.id, "/2026/11/db.sql", 0);
fs.writeBytes("db-copy.sql", $data);
seafile.put($c, $lib.id, "/2026/11/notes.txt", fs.readBytes("notes.txt"), false);
```

`get` caps the body at `DOWNLOAD_LIMIT` (64 MiB) for `maxBytes` 0. `put`
without `replace` stores a taken name as `notes (1).txt` and returns the
`Entry` with the name it got. `putResumable` uploads large files in chunks.

## Requirements

Jennifer 0.26.0 or newer, the default `jennifer` binary (not
`jennifer-tiny`), and the `net` capability. Tested against Seafile 13.0
Community Edition; file locks and full-text search need the Professional
edition. Transfers are held in memory (see the manual's Limits).

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/seafile_test.j     # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
