# nginx-gridfs-module

[![Build & Test][build-test-badge]][build-test-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![GridFS][gridfs-badge]][gridfs-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![Reload][reload-badge]][reload-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/build-test.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/freebsd.yml
[gridfs-badge]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/gridfs.yml/badge.svg
[gridfs-link]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/gridfs.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/valgrind.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/reload.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-gridfs-module/actions/workflows/lint.yml

Serve files out of MongoDB's GridFS with nginx.  A location names a database
and a field, the rest of the URI is the key, and the file comes back with
the content type it was stored with, a Last-Modified from its upload date
and an ETag from its md5 -- byte ranges included, so a media player can seek
and a download can be resumed.

## Directives

### mongo

**syntax:** `mongo <uri>`

**syntax:** `mongo <host>[:<port>] ...`

**syntax:** `mongo <replica set> <host>[:<port>] ...`

**context:** location

Where MongoDB is.  The port defaults to 27017.

A single argument beginning with `mongodb://` or `mongodb+srv://` is taken
as a connection URI, as it stands:

```nginx
location /files/ {
    mongo mongodb://127.0.0.1:27017/?serverSelectionTimeoutMS=2000;
    gridfs media field=_id type=objectid;
}
```

That is the form to prefer, and the only way to reach everything the driver
can be told -- TLS, read preferences, the authentication source, and above
all `serverSelectionTimeoutMS`, which is **30 seconds by default and is
waited out in the worker**.

Two or more arguments are a replica set, the first word being its name:

```nginx
location /files/ {
    mongo rs0 db1.example.org db2.example.org db3.example.org;
    gridfs media;
}
```

The database in the path of a URI is ignored: the database to read is the
one the `gridfs` directive names.

### gridfs

**syntax:** `gridfs <database> [root_collection=<name>] [field=_id|filename] [type=objectid|string|int] [user=<user>] [pass=<password>]`

**context:** location

The database to read, and how to read the key out of the request.

- `root_collection` -- the GridFS prefix, `fs` by default, so the
  collections are `fs.files` and `fs.chunks`
- `field` -- `_id`, the default, or `filename`
- `type` -- how to read the key: `objectid` (the default), `string` or
  `int`.  `field=filename` requires `type=string`
- `user`, `pass` -- credentials, when the URI form is not used.  Both are
  percent-encoded into the URI, so a password with an `@` or a `/` in it
  needs no quoting here

```nginx
location /files/ {
    mongo 127.0.0.1:27017;
    gridfs media field=filename type=string root_collection=uploads;
}
```

`GET /files/holiday.jpg` then answers with the file stored under that name
in `uploads.files`.

A key that cannot name a file -- something that is not an object id where
`type=objectid` is set, or not a number where `type=int` is -- answers 404
without asking MongoDB anything.

## What it does not do

Writing.  This serves files; `mongofiles`, a driver, or anything else puts
them there.

Several ranges in one request.  One `Range: bytes=a-b` is answered with a
206; a header asking for more than one range is ignored and the whole file
is sent, which a server is allowed to do.  Answering it properly means
building a `multipart/byteranges` body out of a file that is read across a
network.

Reading is synchronous: libmongoc is a blocking library, and a worker
fetching a file is not serving anything else meanwhile.  Several workers and
small files are what this is good for.  A request also holds as much memory
as the part of the file it asks for -- the buffers are sent as they are
read, but they cannot be reused until the client has taken them.

## Building

Needs libmongoc: `mongo-c-driver` on FreeBSD, `libmongoc-dev` and
`libbson-dev` on Debian and its relatives.  `config` asks `pkg-config` for
`mongoc2` and `bson2` first and falls back to `libmongoc-1.0` and
`libbson-1.0`, so either generation works.

```sh
./configure --add-module=/path/to/nginx-gridfs-module
```

or as a loadable module:

```sh
./configure --with-compat --add-dynamic-module=/path/to/nginx-gridfs-module
```

```nginx
load_module modules/ngx_http_gridfs_module.so;
```

## Testing

```sh
ci/build.sh 1.30.5 /tmp/nginx-gridfs
TEST_NGINX_BINARY=/tmp/nginx-gridfs/sbin/nginx prove -r t/
ci/mongodb.sh
ci/gridfs.sh /tmp/nginx-gridfs/sbin/nginx
```

`t/` needs no database: it asks which configurations are accepted and
refused, and what a request gets for a key that cannot name a file.

`ci/gridfs.sh` is the one that looks at the product.  `ci/mongodb.sh` puts a
server and two files in `ci-work/` -- one small enough for a single GridFS
chunk, one far bigger -- and then the files are fetched through nginx and
compared byte for byte, with the ranges, the content type, the ETag, a HEAD
request, and ten requests at once.

On Linux the server and `mongofiles` come from MongoDB's own archives,
pinned by digest in `.github/versions.env`, because MongoDB is not a
package on Ubuntu -- it was dropped over the licence change.  MongoDB
publishes no FreeBSD archive, so `ci/mongodb.sh` uses an installed server
there instead, `databases/mongodb70` with `databases/mongodb-tools` beside
it; the workflow still runs the end-to-end check on Linux only.

## License

The module is Michael Dirolf's and is dual licensed under the Apache License
2.0 and the GNU GPL, version 2 or later; see [LICENSE](LICENSE).  The driver
layer was rewritten for libmongoc, and the scaffolding around it is new, but
both are derived work and stay under those terms.
