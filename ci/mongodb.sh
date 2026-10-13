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
# digest in .github/versions.env, and are unpacked under ci-work/, so there
# is nothing to install and nothing of the host's to disturb.  Ubuntu
# dropped MongoDB over the licence change, and MongoDB publishes no FreeBSD
# archive -- FreeBSD carries the server in its ports tree instead
# (databases/mongodb70 and newer), which is a different mechanism than a
# pinned archive and not what this script does.
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
	echo "ci/mongodb.sh: on FreeBSD the ports tree has one: databases/mongodb70" >&2
	echo "ci/mongodb.sh: and databases/mongodb-tools." >&2
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
MONGOIMPORT=$TOOLS/mongoimport

[ -x "$MONGOD" ] || { echo "ci/mongodb.sh: no mongod at $MONGOD" >&2; exit 1; }
[ -x "$MONGOFILES" ] || {
	echo "ci/mongodb.sh: no mongofiles at $MONGOFILES" >&2
	exit 1
}
[ -x "$MONGOEXPORT" ] || {
	echo "ci/mongodb.sh: no mongoexport at $MONGOEXPORT" >&2
	exit 1
}
[ -x "$MONGOIMPORT" ] || {
	echo "ci/mongodb.sh: no mongoimport at $MONGOIMPORT" >&2
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
#
# None of them is given a --type.  mongofiles accepts the option and
# writes the content type nowhere -- the records below say so themselves,
# with an empty metadata document and no contentType field -- and it is
# why the content-type case was answered with the default type for a
# while.  The records that need one get their field written straight into
# them further down, each in the place its own case is about.  plain.txt
# keeps none at all, so that the location's default_type has to be used.
for name in small.txt plain.txt meta.txt evil.txt; do
	"$MONGOFILES" --uri "$uri" --db "$DB" --quiet \
		put "$name" --local "$WORK/small.txt" > /dev/null
done

"$MONGOFILES" --uri "$uri" --db "$DB" --quiet \
	put large.bin --local "$WORK/large.bin" > /dev/null

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
meta_id=$(oid_of meta.txt)
evil_id=$(oid_of evil.txt)

for pair in "small.txt:$small_id" "large.bin:$large_id" \
	"plain.txt:$plain_id" "meta.txt:$meta_id" "evil.txt:$evil_id"
do
	if [ -z "${pair#*:}" ]; then
		echo "ci/mongodb.sh: no object id for ${pair%%:*} in fs.files" >&2
		printf '%s\n' "$files_json" | sed 's/^/ci\/mongodb.sh:   /' >&2
		exit 1
	fi
done

echo "ci/mongodb.sh: small.txt is $small_id, large.bin is $large_id"

# ------------------------------------------------------- the content types
#
# Each of the three cases needs its content type in a particular place, and
# that is written here rather than left to a tool:
#
#   small.txt  the top-level contentType, deprecated out of the GridFS
#              specification in 2019 and still what a file written before
#              that carries
#   meta.txt   metadata.contentType, where it has belonged since
#   evil.txt   a value with a CR and an LF in it, which has to be refused
#              rather than ending the header and starting one of its own
#
# --mode=merge sets those fields and leaves the rest of each record alone.
# The ids are the ones just read out of fs.files, so there is nothing for
# the upsert to insert.
cat > "$WORK/types.json" <<EOF
{"_id":{"\$oid":"$small_id"},"contentType":"text/plain"}
{"_id":{"\$oid":"$meta_id"},"metadata":{"contentType":"text/csv"}}
{"_id":{"\$oid":"$evil_id"},"contentType":"text/plain\r\nX-Injected: yes"}
EOF

"$MONGOIMPORT" --uri "$uri" --db "$DB" --collection fs.files \
	--mode=merge --upsertFields _id --file "$WORK/types.json" \
	> "$WORK/mongoimport.log" 2>&1 || {
	echo "ci/mongodb.sh: mongoimport failed" >&2
	sed 's/^/ci\/mongodb.sh:   /' "$WORK/mongoimport.log" >&2 2>/dev/null || true
	exit 1
}

# What is actually in the records now, which is the thing every answer
# below is compared against.
"$MONGOEXPORT" --uri "$uri" --db "$DB" --collection fs.files \
	--out "$WORK/files.json" > "$WORK/mongoexport.log" 2>&1 || {
	echo "ci/mongodb.sh: mongoexport failed" >&2
	sed 's/^/ci\/mongodb.sh:   /' "$WORK/mongoexport.log" >&2 2>/dev/null || true
	exit 1
}
sed 's/^/ci\/mongodb.sh:   /' "$WORK/files.json"

cat > "$WORK/paths.env" <<EOF
MONGO_WORK=$WORK
MONGO_SMALL=$WORK/small.txt
MONGO_LARGE=$WORK/large.bin
MONGO_URI=$uri
MONGO_SMALL_ID=$small_id
MONGO_LARGE_ID=$large_id
MONGO_PLAIN_ID=$plain_id
EOF
