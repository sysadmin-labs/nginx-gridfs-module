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
TOOLS=$WORK/mongodb-database-tools-ubuntu2204-x86_64-$MONGOTOOLS_VERSION/bin
MONGOFILES=$TOOLS/mongofiles
MONGOEXPORT=$TOOLS/mongoexport

[ -x "$MONGOD" ] || { echo "ci/mongodb.sh: no mongod at $MONGOD" >&2; exit 1; }
[ -x "$MONGOFILES" ] || {
	echo "ci/mongodb.sh: no mongofiles at $MONGOFILES" >&2
	exit 1
}
[ -x "$MONGOEXPORT" ] || {
	echo "ci/mongodb.sh: no mongoexport at $MONGOEXPORT" >&2
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

# The database is named with --db and not in the path of the URI.
# mongofiles with a URI that carries a database wrote its files somewhere
# else -- "mongofiles list" through the same URI listed them happily, while
# mongoexport and the module, both looking in $DB, found an empty
# collection.  That was the reason every lookup answered 404.  mongoexport
# refuses --db together with a database in the URI, so neither gets one.
uri="mongodb://127.0.0.1:$PORT"

# --local is what names the file on disk; the first argument is the name it
# gets in GridFS.  Handing the path over as the name, which is what
# "mongofiles put <path>" does, stores the whole path -- and then nothing
# can be asked for by a sensible name.
"$MONGOFILES" --uri "$uri" --db "$DB" --quiet \
	put small.txt --local "$WORK/small.txt" --type text/plain > /dev/null

"$MONGOFILES" --uri "$uri" --db "$DB" --quiet \
	put large.bin --local "$WORK/large.bin" \
	--type application/octet-stream > /dev/null

# A third one with no content type, so that the location's own default_type
# has to be used for it.
"$MONGOFILES" --uri "$uri" --db "$DB" --quiet \
	put plain.txt --local "$WORK/small.txt" > /dev/null

echo "ci/mongodb.sh: database $DB holds:"
"$MONGOFILES" --uri "$uri" --db "$DB" --quiet list | sed 's/^/ci\/mongodb.sh:   /'

# The object ids are read back rather than chosen.  "mongofiles put_id"
# takes an id, but what it makes of one is its business and not something to
# rely on; mongoexport prints what is actually in fs.files, and an ObjectId
# comes out as {"$oid":"..."} -- which also says it is an ObjectId and not a
# string that looks like one.
# The whole document rather than selected fields, and stderr kept: a
# mongoexport that refuses an option would otherwise say so into /dev/null
# and look like an empty collection.
# --out rather than stdout: mongoexport writes its documents to the file it
# is given, and asking for stdout inside a command substitution came back
# empty with nothing on stderr either.
"$MONGOEXPORT" --uri "$uri" --db "$DB" --collection fs.files \
	--out "$WORK/files.json" > "$WORK/mongoexport.log" 2>&1 || {
	echo "ci/mongodb.sh: mongoexport failed" >&2
	sed 's/^/ci\/mongodb.sh:   /' "$WORK/mongoexport.log" >&2 2>/dev/null || true
	exit 1
}

files_json=$(cat "$WORK/files.json" 2>/dev/null)

if [ -z "$files_json" ]; then
	echo "ci/mongodb.sh: mongoexport wrote no documents for fs.files" >&2
	sed 's/^/ci\/mongodb.sh:   /' "$WORK/mongoexport.log" >&2 2>/dev/null || true
	exit 1
fi

oid_of() {
	printf '%s\n' "$files_json" |
		grep -F "\"filename\":\"$1\"" |
		sed -n 's/.*"\$oid":"\([0-9a-f]*\)".*/\1/p' |
		head -1
}

small_id=$(oid_of small.txt)
large_id=$(oid_of large.bin)
plain_id=$(oid_of plain.txt)

for pair in "small.txt:$small_id" "large.bin:$large_id" "plain.txt:$plain_id"; do
	if [ -z "${pair#*:}" ]; then
		echo "ci/mongodb.sh: no object id for ${pair%%:*} in fs.files" >&2
		printf '%s\n' "$files_json" | sed 's/^/ci\/mongodb.sh:   /' >&2
		exit 1
	fi
done

echo "ci/mongodb.sh: small.txt is $small_id, large.bin is $large_id"

cat > "$WORK/paths.env" <<EOF
MONGO_WORK=$WORK
MONGO_SMALL=$WORK/small.txt
MONGO_LARGE=$WORK/large.bin
MONGO_URI=$uri
MONGO_SMALL_ID=$small_id
MONGO_LARGE_ID=$large_id
MONGO_PLAIN_ID=$plain_id
EOF
