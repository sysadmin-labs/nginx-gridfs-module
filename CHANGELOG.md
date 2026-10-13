# Changelog

Newest first.  Dates are release dates.

## Unreleased

### Changed

- **The driver layer is rewritten for libmongoc.**  What it replaces talked
  to the legacy mongo-c-driver, which this module carried as a git
  submodule: that driver has not existed for years, the submodule pointed at
  a `git://` URL GitHub stopped serving in 2021, and the directory it should
  have filled was empty.  Nothing here could be built any more.

  libmongoc does by itself what roughly half of this file used to do by
  hand -- connecting, reconnecting, authenticating, finding the primary of a
  replica set, keeping connections for reuse.  All of that is gone, behind a
  connection URI and a client pool, and the module is about half the size it
  was.

  The directives are unchanged, so a configuration written for the old
  module needs no edit.  The URI is built from them, with the user and the
  password percent-encoded -- a password with an `@` or a `/` in it used to
  end the userinfo or the host part early, and the failure looked like a
  connection problem rather than a quoting one.

- The body is sent as it is read rather than collected first.  Each chunk
  goes out as soon as it arrives, so a client starts receiving before the
  whole file has been fetched.

### Added

- `mongo <uri>`: a single argument beginning with `mongodb://` or
  `mongodb+srv://` is taken as a connection URI as it stands.  Without it
  there is no way to reach anything the driver can be told, and one of those
  things matters a great deal here: `serverSelectionTimeoutMS` is thirty
  seconds by default, and libmongoc waits it out **in the worker**, which is
  not serving anything else meanwhile.

- Byte ranges are answered with a `206` and a `Content-Range`, for a single
  `Range: bytes=a-b`, `bytes=a-` or `bytes=-n`; a range that starts past the
  end is a `416` with the size.  The file is seeked to, so only the slice
  asked for is read out of the database.  nginx's own range filter would
  have been less code and would have read the whole file to throw most of it
  away.  More than one range in a header is ignored and the whole file is
  sent, which a server is allowed to do.

- An ETag, from the file's md5, and a Last-Modified from its upload date.
  Both only when the record has them: md5 was taken out of the GridFS
  specification in 2019, so a file written by a recent driver has none.

- A content type from the file's own record, falling back to the location's
  `default_type`.

- Everything a connection needs is decided while the configuration is read,
  not when a worker starts.  A fault found in the worker is written into a
  log nobody is watching: nginx has daemonized by then and whoever started
  it has already been told the start succeeded.  So a `gridfs` without a
  `mongo`, and a URI the driver will not take, are refused by `nginx -t`.

- `t/`, which needs no database: which configurations are accepted and
  refused, and what a request gets for a key that cannot name a file.  A key
  that is not an object id where `type=objectid` is set answers 404 without
  asking MongoDB anything, which is both the faster answer and the one that
  does not depend on a server being up.

- `ci/mongodb.sh` and `ci/gridfs.sh`, with a workflow of their own, for what
  `t/` cannot reach: a server with two files in it -- one small enough for a
  single GridFS chunk and one far bigger -- fetched through nginx and
  compared byte for byte, with the ranges, the content type, a HEAD request,
  a key that is not there, and ten requests at once.

  Both mongod and mongofiles come from MongoDB's own archives, pinned by
  digest: MongoDB is not a package on either system this is built on.
  Ubuntu dropped it over the licence change and FreeBSD has no server port
  any more -- which is also why this runs on Linux only, there being no
  FreeBSD server build to use.

- The reload gate asks the module without needing a database: it requests a
  well-formed object id from a port nothing listens on and insists on a 503.
  A reload that dropped the module answers 404, one that lost the pool
  answers 500, and only a module that is still there and still trying
  answers 503.

- `config` finds libmongoc through `pkg-config`, asking for `mongoc2` and
  `bson2` first and falling back to `libmongoc-1.0` and `libbson-1.0`.  The
  library changed name between its 1.x and 2.x releases and the headers
  moved with it; the FreeBSD port carries two patches for exactly that, one
  of them replacing the hardcoded include paths this file had.  Neither is
  needed any more.

- The loadable-module case, which the old `config` did not have at all: it
  only ever appended to `HTTP_MODULES` and `NGX_ADDON_SRCS`, so
  `--add-dynamic-module` did not work.  libmongoc goes on this module's own
  link line rather than into `CORE_LIBS`, where every other dynamic module
  of the same build would be linked against it as well.

- The scaffolding the other modules in this organization carry: a version
  and digest pin for every build input, the release matrix, the FreeBSD
  virtual machine, A/UBSan, valgrind, CodeQL, shellcheck and actionlint.

### Removed

- The `mongo-c-driver` submodule and the empty directory it left behind.

- `README.rst`, whose installation instructions were about that submodule.
