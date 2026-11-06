<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Trash and history

Seafile keeps a library's history as commits. A deleted file stays in an
older commit until the history limit drops it; the trash lists those items.

## The trash

```jennifer
for (def t in seafile.trashAll($c, $id, "/")) {
    io.printf("%s deleted %d\n", $t.path, $t.deleted);
}
```

The server scans the history in steps: `trash` returns one page and a
`scanStat` cursor, `more` says whether it has more to scan. `trashAll`
follows the cursor; it stops when `more` is false, at an empty cursor or at
a cursor it followed before, and refuses past `MAX_PAGES` (1000) pages.
There is no item cap: memory is bounded by `MAX_PAGES` pages of at most the
reply limit each (`REPLY_LIMIT`, 64 MiB, unless `withReplyLimit` changes
it), the same for `fileHistory`.

`restore` puts items back where they were (`trash/revert-dirents`), one
request per commit the items share; an item the server cannot restore
throws with its message:

```jennifer
def gone as list of seafile.TrashItem init seafile.trashAll($c, $id, "/docs");
seafile.restore($c, $id, $gone);
```

`cleanTrash` drops the history older than `keepDays` days, 0 for all of it.
There is no undo. Library admins only, and only when the server sets
`ENABLE_USER_CLEAN_TRASH`.

## File history

```jennifer
def h as list of seafile.Revision init seafile.fileHistory($c, $id, "/docs/plan.md");
for (def r in $h) {
    io.printf("%s %d %s\n", $r.commitId, $r.size, $r.description);
}
seafile.revertFile($c, $id, "/docs/plan.md", $h[1].commitId);
```

`fileHistory` follows the server's `next_start_commit` (pages of the
server's default 50 versions) under the same `MAX_PAGES` guard. The server
ends a page at a rename (the last version carries `rev_renamed_old_path`);
the next page asks for the old path, as the web UI does, so the history
goes back past renames. `revertFile` restores a file to the version a
commit holds; the current content becomes an older version.
`revertDir` restores a folder to the state a commit holds, for example the
`commitId` of a `TrashItem` deleted inside it.
