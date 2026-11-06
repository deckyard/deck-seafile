<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Search

## By name, in one library

`searchNames` finds files and folders of one library whose name contains a
string. It works on Community Edition. A folder has `type` `dir` (the
server says `folder`) and a path without a trailing `/`:

```jennifer
for (def e in seafile.searchNames($c, $id, "invoice")) {
    io.printf("%s %s %d\n", $e.type, $e.path, $e.size);
}
```

## Full text

`search` uses the Professional edition's search index (`/api2/search/`);
Community Edition answers HTTP 403. The zero `SearchOptions` searches every
library the account reaches:

```jennifer
def o as seafile.SearchOptions;
$o.repoId = $id;
$o.path = "/contracts";
$o.perPage = 50;
for (def h in seafile.search($c, "termination clause", $o)) {
    io.printf("%s %s\n", $h.repoName, $h.path);
}
```

`path` needs `repoId`; `page` counts from 1.
