#!/bin/sh
#
# Put a MongoDB where the tests can reach it, with two files in GridFS.
#
# usage: ci/mongodb.sh
#
#     MONGO_PORT   port to listen on, 17017 by default
#     MONGO_DB     database to use, ngxtest by default
#
# The server and mongofiles come from MongoDB's own archives, pinned by
# digest in .github/versions.env, and are unpacked under ci-work/.  Neither
# is a package on the systems this is built on: Ubuntu dropped MongoDB over
# the licence change, and FreeBSD has no server port any more either -- so
# there is nothing to install and nothing of the host's to disturb.
#
# It leaves an already running server on that port alone.

set -eu

PORT=${MONGO_PORT:-17017}
DB=${MONGO_DB:-ngxtest}
SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}/mongodb

PINS=$SRC/.github/versions.env
[ -r "$PINS" ] || {
	echo "ci/mongodb.sh: cannot read $PINS" >&2
	exit 1
}
# shellcheck source=../.github/versions.env
. "$PINS"

if command -v nc > /dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
	echo "ci/mongodb.sh: something already listens on port $PORT"
	exit 0
fi

case $(uname -s) in
Linux)  ;;
*)
	echo "ci/mongodb.sh: MongoDB publishes no server archive for $(uname -s)," >&2
	echo "ci/mongodb.sh: so this cannot run here.  The module builds and the" >&2
	echo "ci/mongodb.sh: suite in t/ runs; only this script needs a server." >&2
	exit 2
	;;
esac

rm -rf "$WORK"
mkdir -p "$WORK/data" "$WORK/dl"

base=https://fastdl.mongodb.org

"$SRC/ci/fetch-verify.sh" \
	"$base/linux/mongodb-linux-x86_64-ubuntu2204-$MONGODB_VERSION.tgz" \
	"$MONGODB_SHA256" "$WORK/dl/mongodb.tgz"

"$SRC/ci/fetch-verify.sh" \
	"$base/tools/db/mongodb-database-tools-ubuntu2204-x86_64-$MONGOTOOLS_VERSION.tgz" \
	"$MONGOTOOLS_SHA256" "$WORK/dl/mongotools.tgz"

tar xzf "$WORK/dl/mongodb.tgz" -C "$WORK"
tar xzf "$WORK/dl/mongotools.tgz" -C "$WORK"

MONGOD=$WORK/mongodb-linux-x86_64-ubuntu2204-$MONGODB_VERSION/bin/mongod
MONGOFILES=$WORK/mongodb-database-tools-ubuntu2204-x86_64-$MONGOTOOLS_VERSION/bin/mongofiles

[ -x "$MONGOD" ] || { echo "ci/mongodb.sh: no mongod at $MONGOD" >&2; exit 1; }
[ -x "$MONGOFILES" ] || {
	echo "ci/mongodb.sh: no mongofiles at $MONGOFILES" >&2
	exit 1
}

"$MONGOD" --version | sed -n '1s/^/ci\/mongodb.sh: /p'

"$MONGOD" \
	--dbpath "$WORK/data" \
	--bind_ip 127.0.0.1 \
	--port "$PORT" \
	--logpath "$WORK/mongod.log" \
	--pidfilepath "$WORK/mongod.pid" \
	--fork > "$WORK/fork.log" 2>&1 || {
	cat "$WORK/fork.log" >&2
	tail -40 "$WORK/mongod.log" >&2 2>/dev/null || true
	exit 1
}

echo "ci/mongodb.sh: mongod is up on port $PORT"

# ------------------------------------------------------------- the two files
#
# One small enough to live in a single GridFS chunk and one far bigger, so
# that reading across chunk boundaries is part of what the tests ask.  The
# contents are generated rather than random: a comparison has to be able to
# say which byte went wrong.

seq 1 100 > "$WORK/small.txt"
i=0
: > "$WORK/large.bin"
while [ "$i" -lt 2000 ]; do
	printf '%07d-the quick brown fox jumps over the lazy dog-%07d\n' \
		"$i" "$i" >> "$WORK/large.bin"
	i=$((i + 1))
done

uri="mongodb://127.0.0.1:$PORT/$DB"

"$MONGOFILES" --uri "$uri" --quiet \
	put_id "$WORK/small.txt" '{"$oid":"000000000000000000000001"}' \
	--type text/plain > /dev/null

"$MONGOFILES" --uri "$uri" --quiet \
	put_id "$WORK/large.bin" '{"$oid":"000000000000000000000002"}' \
	--type application/octet-stream > /dev/null

# A third one under a name, for field=filename, and with no content type so
# that the location's own default_type has to be used.
"$MONGOFILES" --uri "$uri" --quiet put "$WORK/small.txt" > /dev/null

echo "ci/mongodb.sh: database $DB holds:"
"$MONGOFILES" --uri "$uri" --quiet list | sed 's/^/ci\/mongodb.sh:   /'

cat > "$WORK/paths.env" <<EOF
MONGO_WORK=$WORK
MONGO_SMALL=$WORK/small.txt
MONGO_LARGE=$WORK/large.bin
MONGO_URI=$uri
EOF
