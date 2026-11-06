<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Files and folders

Paths are absolute in their library: `/` is the root, `/docs/a.txt` a file.
A relative path, a trailing `/`, an empty, `.` or `..` segment, or a control
character is refused before anything is sent.

## Listing

```jennifer
for (def e in seafile.listDir($c, $id, "/docs", "", false)) {
    io.printf("%s %s %d\n", $e.type, $e.path, $e.size);
}
def files as list of seafile.Entry init seafile.listDir($c, $id, "/", "file", true);
```

`type` filters to `file` or `dir` (`""` for both); `recursive` returns every
depth below the folder in one request, each entry with its full path.

`fileDetail` and `dirDetail` describe one item. `exists` asks for a file,
then for a folder: one request for a file or `/`, two otherwise. It answers
false only for the server's 404 `File ... not found` / `Folder ... not found`;
a missing library or any other refusal throws.

## Folders

```jennifer
def made as string init seafile.mkdir($c, $id, "/docs", false);
seafile.mkdir($c, $id, "/backups/2026/11", true);
```

Without `parents` the parent must exist and a taken name gets a free one:
`mkdir` of an existing `/docs` makes `/docs (1)` and returns that path. With
`parents` every missing folder on the way is made and an existing folder is
left as it is (`create_parents`). A library API token client has no
`create_parents`; `mkdir` then probes each level and makes the missing ones.

## Download

```jennifer
def data as bytes init seafile.get($c, $id, "/docs/a.txt", 0);
def big as bytes init seafile.get($c, $id, "/video.mkv", -1);
```

`get` asks for a download link, then fetches it without `Authorization`.
`maxBytes` caps the file: 0 for `DOWNLOAD_LIMIT` (64 MiB), a negative value
for no cap.

## Upload

```jennifer
def e as seafile.Entry init seafile.put($c, $id, "/docs/report.pdf", fs.readBytes("report.pdf"), false);
io.printf("stored as %s\n", $e.path);
```

`put` asks for an upload link for the folder, then posts a multipart form
(`parent_dir`, `replace`, `file`) to it. The folder must exist. With
`replace` an existing file is overwritten; without it Seafile stores the
upload as `report (1).pdf`, and the returned `Entry` shows that name.

`update` overwrites an existing file through its update link and returns
the new file id; it fails when the file is missing.

With an account token both first ask `file-uploaded-bytes` and drop a temp
file an interrupted chunked upload left at that path (see below), so a later
`putResumable` with `resume` true cannot join its stale bytes. The drop is
one chunk at the temp file's size to the folder's update link with
`?head=<a commit no library has>`: the server completes the temp file,
fails the update with 500, and deletes the temp file; nothing is stored and
no version is added. Requests: `put` 3 (5 with a temp file), `update` 3 (4).
The drop is best effort: when the update link or the drop fails (a share
that allows upload but not web edit answers 403 to the link), the upload
goes ahead, bypasses the temp file and leaves it.

The server keys a temp file by library and path, not by client or user.
Dropping it aborts a chunked upload of the same path that another client
(another job, the web UI, another user of a shared library) has in progress:
its next chunk is refused. This is inherent to clearing the temp file.

A library API token has no `file-uploaded-bytes` and no update link, so its
`put` (2 requests) leaves such a temp file in place; the server expires
temp files after `http_temp_file_ttl` (3 days by default).

File names: the C fileserver (the Community Edition default) reads a
multipart file name verbatim, without unescaping `\"` or `\\`, and keeps
only what follows its last `\`. `put` therefore sends a name with `"` as one
chunk with the percent-encoded header `putResumable` uses, which both
fileservers decode (same request count; an empty file with such a name
throws), and `put` and `putResumable` refuse a name with `\`: it would be
stored under another name. `update` takes the name from the path and is not
affected.

### Resumable upload

```jennifer
def img as seafile.Entry init seafile.putResumable($c, $id, "/iso/disk.img", $data, 0, true, false);
# after a failure, the same data again:
$img = seafile.putResumable($c, $id, "/iso/disk.img", $data, 0, true, true);
```

`putResumable` posts the data to one upload link in chunks (`CHUNK_SIZE`,
8 MiB, for `chunkSize` 0), each with
`Content-Range: bytes <first>-<last>/<total>` and
`Content-Disposition: attachment; filename="<name>"`, the name
percent-encoded. The server keeps the chunks in a temp file per library and
path and joins them after the last one. It accepts a chunk only at the temp
file's size and does not check what the temp file holds.

With `resume` false the upload starts at 0. With an account token a temp
file `file-uploaded-bytes` reports (of any size) is dropped first, as `put`
does (two requests more), then the chunks go from 0, so a per-request body
limit in front of the fileserver still holds. A library API token can
neither ask nor drop: the first chunk answers HTTP 400 over a stale temp
file, and the data then goes through `put`, one POST of the whole data
(no `Content-Range`, nothing joined; the temp file stays).

With `resume` true and an account token the upload continues at the offset
`file-uploaded-bytes` reports. Resume only with the same data as the
interrupted call: the server joins other data to the stale prefix without an
error. When the temp file holds every byte but was never stored, the server
refuses any further chunk, so the temp file is dropped and the chunks start
at 0; an offset above the size throws. A library API token starts at 0 as
with `resume` false.

With an account token a first chunk that answers HTTP 400 (a temp file
appeared or changed after the offset was read) makes `putResumable` read
the offset again, drop the temp file and restart at 0, once; a second 400
throws. A name that is not NFC (macOS-style decomposed) can hit this every
time: the fileserver keys the temp file by the normalised name, while
`file-uploaded-bytes` looks up the name as given and reports 0.

## Rename, copy, move, remove

```jennifer
def renamed as string init seafile.rename($c, $id, "/docs/a.txt", "b.txt");
seafile.copy($c, $id, "/docs/b.txt", $other, "/inbox");
seafile.move($c, $id, "/old", $other, "/archive");
seafile.copyItems($c, $id, "/docs", ["a.txt", "b.txt"], $id, "/backup");
seafile.remove($c, $id, "/tmp");
seafile.removeItems($c, $id, "/docs", ["x.txt", "y.txt"]);
```

`rename` tries the file endpoint, then the folder endpoint, and returns the
new path. `copy` and `move` (and the batch forms) work across libraries
(a library API token: within its library), for files and folders alike.
In all of them a taken name gets a free one. The target folder must exist.
A missing source answers HTTP 500 from the server.

`remove` and `removeItems` move items to the library's trash; a name that is
not there is skipped without an error.

## Background copy and move

For large trees, `copyAsync` and `moveAsync` return a task id at once:

```jennifer
def task1 as string init seafile.copyAsync($c, $id, "/", ["photos"], $other, "/");
def p as seafile.Progress init seafile.taskProgress($c, $task1);
while (not $p.successful and not $p.failed and not $p.canceled) {
    time.sleep(time.fromSeconds(1));
    $p = seafile.taskProgress($c, $task1);
}
```

`cancelTask` stops one.

## Locks

`lockFile` and `unlockFile` need the Professional edition; Community
Edition answers HTTP 403 `file lock feature only supported in professional
edition.`
