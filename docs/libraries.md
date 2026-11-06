<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Libraries

A library (repository) holds a tree of files and folders; every path is
relative to one. `libraries` lists those the account reaches, filtered by
one of `LIBRARY_TYPES` (`mine`, `shared`, `group`, `org`) or `""` for all:

```jennifer
for (def lib in seafile.libraries($c, "mine")) {
    io.printf("%s %s|pad=20 %d bytes\n", $lib.id, $lib.name, $lib.size);
}
def one as seafile.Library init seafile.library($c, $id);
```

`Library.type` is `repo` for the account's own, `srepo` for one shared with
it, `grepo` for a group library.

## Create, rename, remove

```jennifer
def lib as seafile.Library init seafile.createLibrary($c, "projects", "");
seafile.renameLibrary($c, $lib.id, "projects-2026");
seafile.removeLibrary($c, $lib.id);
```

`removeLibrary` deletes the library with everything in it. A system admin
can restore it for a while (admin API, not in this deck).

## Encrypted libraries

A non-empty `password` makes `createLibrary` create an encrypted library:

```jennifer
def vault as seafile.Library init seafile.createLibrary($c, "vault", os.getEnv("VAULT_PASSWORD"));
```

The password is sent to the server, which derives the keys; `decrypt` sends
it again to unlock the library there, and the server keeps the key in memory
for a time. A setup that must keep the password from the server uses the
desktop client.

```jennifer
seafile.decrypt($c, $vault.id, os.getEnv("VAULT_PASSWORD"));
io.printf("%d\n", len(seafile.listDir($c, $vault.id, "/", "", false)));
```

A wrong password answers HTTP 400 `Incorrect password`.
