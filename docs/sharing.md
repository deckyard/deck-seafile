<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Sharing

## Users and groups

A library (`path` `/`) or a folder in it is shared with a user (`kind`
`user`, `who` the user id) or a group (`kind` `group`, `who` the group id as
digits), with a permission from `SHARE_PERMISSIONS` (`r`, `rw`, `admin`;
`preview`, `cloud-edit` and `invisible` on Professional) or a custom share
permission `custom-<id>`:

```jennifer
seafile.share($c, $id, "/", "user", "bob@example.com", "r");
seafile.share($c, $id, "/projects", "group", "3", "rw");
for (def s in seafile.shares($c, $id, "/", "user")) {
    io.printf("%s %s\n", $s.user, $s.permission);
}
seafile.changeShare($c, $id, "/", "user", "bob@example.com", "rw");
seafile.unshare($c, $id, "/projects", "group", "3");
```

The user id is what `Account.email` shows: an e-mail address, or on Seafile
13 a virtual `<hex>@auth.local` id whose address is `contactEmail`. Sharing
with the contact address fails with `User ... not found.` The server answers a
share it cannot make (unknown user, already shared) with a `failed` list;
`share` throws with its message.

`sharedFolders` lists the folders (not whole libraries) the account shares.
`sharedWithMe` lists the libraries shared with the account
(`/api2/beshared-repos/`): `kind` `user`, `group` or `public`. Seafile 13.0
sends the sharer (`user`) and `permission` for a share with the user only; a
group entry carries neither, and no entry carries a display name, group or
admin flag, so `userName`, `groupId`, `groupName` and `isAdmin` are zero.
`libraries($c, "shared")` lists the libraries shared with the user as
`Library` values.

## Starred items

```jennifer
seafile.star($c, $id, "/docs/plan.md");
for (def s in seafile.starred($c)) {
    io.printf("%s %s\n", $s.repoName, $s.path);
}
seafile.unstar($c, $id, "/docs/plan.md");
```

A `path` of `/` stars the library itself.

## Share links

A share link lets anyone with the URL view or download a file or folder.
`ShareLinkOptions`' zero value makes an open link that allows downloads:

```jennifer
def o as seafile.ShareLinkOptions;
$o.password = os.getEnv("LINK_PASSWORD");
$o.expireDays = 7;
$o.noDownload = true;
def l as seafile.ShareLink init seafile.createShareLink($c, $id, "/docs/report.pdf", $o);
io.printf("%s\n", $l.link);
```

The server refuses a password shorter than its
`SHARE_LINK_PASSWORD_MIN_LENGTH`. `canUpload` lets visitors upload into a
shared folder, `canEdit` edit office files. A library API token client
makes links without password or expiry; `createShareLink` refuses either
there instead of dropping them.

`shareLinks` lists every link, `shareLinksOf` those of a library (`path`
`""`) or of one path; `deleteShareLink` takes the link's `token`.

## Upload links

An upload link lets others upload into a folder without an account:

```jennifer
def u as seafile.UploadLink init seafile.createUploadLink($c, $id, "/inbox", "", 30);
io.printf("%s\n", $u.link);
seafile.deleteUploadLink($c, $u.token);
```

`password` `""` and `expireDays` 0 make it open and permanent.
