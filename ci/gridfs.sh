#!/bin/sh
#
# Serve files out of a real GridFS and compare what arrives with what went
# in.
#
# This is the check that looks at what the module is for.  t/ can say which
# configurations are accepted and refused, and what happens for a key that
# cannot exist -- and it can say all of that without a database, which is
# why it is separate.  Whether a file comes back byte for byte, whether a
# range request answers with the right slice, and whether the content type
# and the ETag come out of the file's own record: that needs a server with
# something in it.
#
# usage: ci/gridfs.sh <nginx binary>
#
# Needs the MongoDB ci/mongodb.sh sets up.
#
# Set GRIDFS_LOAD_MODULE to the path of ngx_http_gridfs_module.so to test a
# loadable build.

set -eu

NGINX=${1:?path to the nginx binary missing}
SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}/gridfs
MONGO=${CI_WORK:-$SRC/ci-work}/mongodb
PORT=${GRIDFS_PORT:-18550}
MONGO_PORT=${MONGO_PORT:-17017}
DB=${MONGO_DB:-ngxtest}

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

[ -r "$MONGO/paths.env" ] || {
	echo "ci/gridfs.sh: $MONGO/paths.env is not there" >&2
	echo "ci/gridfs.sh: run ci/mongodb.sh first" >&2
	exit 2
}
# shellcheck source=/dev/null
. "$MONGO/paths.env"

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs" "$WORK/out" "$WORK/tmp"

fail=0
note() {
	echo "  $1" >&2
	fail=1
}

# --------------------------------------------------------------- the nginx

ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

ngx_load=
if [ -n "${GRIDFS_LOAD_MODULE:-}" ]; then
	ngx_load="load_module $GRIDFS_LOAD_MODULE;"
fi

# serverSelectionTimeoutMS is what keeps a failure quick: libmongoc waits
# thirty seconds by default for a server to turn up, and it waits in the
# worker.
cat > "$WORK/conf/nginx.conf" <<EOF
$ngx_load
$ngx_user
daemon on;
master_process on;
worker_processes 1;
pid $WORK/logs/nginx.pid;
error_log $WORK/logs/error.log info;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $WORK/tmp/cb;
    fastcgi_temp_path $WORK/tmp/fc;
    uwsgi_temp_path $WORK/tmp/uw;
    scgi_temp_path $WORK/tmp/sc;
    default_type application/octet-stream;

    server {
        listen 127.0.0.1:$PORT;

        location /id/ {
            mongo mongodb://127.0.0.1:$MONGO_PORT/?serverSelectionTimeoutMS=2000;
            gridfs $DB field=_id type=objectid;
        }

        location /name/ {
            mongo mongodb://127.0.0.1:$MONGO_PORT/?serverSelectionTimeoutMS=2000;
            gridfs $DB field=filename type=string;
        }

        location /host/ {
            mongo 127.0.0.1:$MONGO_PORT;
            gridfs $DB field=_id type=objectid;
        }

        location /other/ {
            mongo mongodb://127.0.0.1:$MONGO_PORT/?serverSelectionTimeoutMS=2000;
            gridfs $DB field=_id type=objectid root_collection=nothing;
        }

        location = /alive {
            return 200 'alive';
        }
    }
}
EOF

"$NGINX" -t -c "$WORK/conf/nginx.conf" -p "$WORK" > "$WORK/out/t.log" 2>&1 ||
	{ cat "$WORK/out/t.log"; exit 1; }
"$NGINX" -c "$WORK/conf/nginx.conf" -p "$WORK"

cleanup() {
	[ -f "$WORK/logs/nginx.pid" ] &&
		kill -QUIT "$(cat "$WORK/logs/nginx.pid")" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

sleep 1

SMALL_ID=000000000000000000000001
LARGE_ID=000000000000000000000002

small_len=$(wc -c < "$MONGO_SMALL" | tr -d ' ')
large_len=$(wc -c < "$MONGO_LARGE" | tr -d ' ')

# ---------------------------------------------------------------- the cases

echo "--- a file that fits in one chunk, by object id ---"
code=$(curl -s -o "$WORK/out/small.bin" -w '%{http_code}' --max-time 20 \
	"http://127.0.0.1:$PORT/id/$SMALL_ID" || true)
if [ "$code" = 200 ] && cmp -s "$WORK/out/small.bin" "$MONGO_SMALL"; then
	echo "  $small_len bytes, byte for byte what went in"
else
	note "code $code, $(wc -c < "$WORK/out/small.bin" | tr -d ' ') of $small_len bytes"
fi

echo "--- a file of many chunks ---"
code=$(curl -s -o "$WORK/out/large.bin" -w '%{http_code}' --max-time 60 \
	"http://127.0.0.1:$PORT/id/$LARGE_ID" || true)
if [ "$code" = 200 ] && cmp -s "$WORK/out/large.bin" "$MONGO_LARGE"; then
	echo "  $large_len bytes, byte for byte"
else
	note "code $code, $(wc -c < "$WORK/out/large.bin" | tr -d ' ') of $large_len bytes"
	cmp "$WORK/out/large.bin" "$MONGO_LARGE" 2>&1 | head -2 | sed 's/^/  /' >&2
fi

echo "--- the content type comes out of the file's own record ---"
ct=$(curl -s -o /dev/null -D - --max-time 20 \
	"http://127.0.0.1:$PORT/id/$SMALL_ID" 2>/dev/null |
	sed -n 's/^[Cc]ontent-[Tt]ype: *//p' | tr -d '\r')
if [ "$ct" = "text/plain" ]; then
	echo "  text/plain, which is what mongofiles was told"
else
	note "Content-Type: \"$ct\", expected text/plain"
fi

echo "--- a file with no content type takes the location's default ---"
name=$(basename "$MONGO_SMALL")
ct=$(curl -s -o /dev/null -D - --max-time 20 \
	"http://127.0.0.1:$PORT/name/$name" 2>/dev/null |
	sed -n 's/^[Cc]ontent-[Tt]ype: *//p' | tr -d '\r')
if [ "$ct" = "application/octet-stream" ]; then
	echo "  application/octet-stream, from default_type"
else
	note "Content-Type: \"$ct\", expected application/octet-stream"
fi

echo "--- by filename ---"
code=$(curl -s -o "$WORK/out/byname.bin" -w '%{http_code}' --max-time 20 \
	"http://127.0.0.1:$PORT/name/$name" || true)
if [ "$code" = 200 ] && cmp -s "$WORK/out/byname.bin" "$MONGO_SMALL"; then
	echo "  the same bytes, found under its name"
else
	note "code $code for /name/$name"
fi

echo "--- a range in the middle of the big file ---"
code=$(curl -s -o "$WORK/out/range.bin" -w '%{http_code}' --max-time 30 \
	-H 'Range: bytes=1000-1999' "http://127.0.0.1:$PORT/id/$LARGE_ID" || true)
dd if="$MONGO_LARGE" of="$WORK/out/range.want" bs=1 skip=1000 count=1000 \
	2>/dev/null
if [ "$code" = 206 ] && cmp -s "$WORK/out/range.bin" "$WORK/out/range.want"; then
	echo "  206 and the thousand bytes from offset 1000"
else
	note "code $code, $(wc -c < "$WORK/out/range.bin" | tr -d ' ') bytes"
fi

echo "--- Content-Range says where the slice came from ---"
cr=$(curl -s -o /dev/null -D - --max-time 30 \
	-H 'Range: bytes=1000-1999' "http://127.0.0.1:$PORT/id/$LARGE_ID" \
	2>/dev/null | sed -n 's/^[Cc]ontent-[Rr]ange: *//p' | tr -d '\r')
if [ "$cr" = "bytes 1000-1999/$large_len" ]; then
	echo "  $cr"
else
	note "Content-Range: \"$cr\", expected \"bytes 1000-1999/$large_len\""
fi

echo "--- an open range, to the end ---"
code=$(curl -s -o "$WORK/out/open.bin" -w '%{http_code}' --max-time 30 \
	-H "Range: bytes=$((large_len - 10))-" \
	"http://127.0.0.1:$PORT/id/$LARGE_ID" || true)
got=$(wc -c < "$WORK/out/open.bin" | tr -d ' ')
if [ "$code" = 206 ] && [ "$got" = 10 ]; then
	echo "  206 and the last ten bytes"
else
	note "code $code, $got bytes, expected 10"
fi

echo "--- the last five bytes, asked for from the end ---"
code=$(curl -s -o "$WORK/out/suffix.bin" -w '%{http_code}' --max-time 30 \
	-H 'Range: bytes=-5' "http://127.0.0.1:$PORT/id/$LARGE_ID" || true)
tail -c 5 "$MONGO_LARGE" > "$WORK/out/suffix.want"
if [ "$code" = 206 ] && cmp -s "$WORK/out/suffix.bin" "$WORK/out/suffix.want"; then
	echo "  206 and the right five bytes"
else
	note "code $code, $(wc -c < "$WORK/out/suffix.bin" | tr -d ' ') bytes"
fi

echo "--- a range that starts past the end ---"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
	-H "Range: bytes=$((large_len + 10))-" \
	"http://127.0.0.1:$PORT/id/$LARGE_ID" || true)
if [ "$code" = 416 ]; then
	echo "  416, with Content-Range naming the size"
else
	note "code $code, expected 416"
fi

echo "--- a HEAD request ---"
out=$(curl -s -I --max-time 20 "http://127.0.0.1:$PORT/id/$LARGE_ID" || true)
code=$(printf '%s' "$out" | sed -n '1s/[^ ]* \([0-9]*\).*/\1/p')
cl=$(printf '%s\n' "$out" | sed -n 's/^[Cc]ontent-[Ll]ength: *//p' | tr -d '\r')
if [ "$code" = 200 ] && [ "$cl" = "$large_len" ]; then
	echo "  200 and Content-Length $cl, with no body"
else
	note "HEAD: code $code, Content-Length \"$cl\", expected $large_len"
fi

echo "--- an object id that is not in the database ---"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
	"http://127.0.0.1:$PORT/id/0000000000000000000000ff" || true)
if [ "$code" = 404 ]; then
	echo "  404"
else
	note "code $code, expected 404"
fi

echo "--- something that is not an object id at all ---"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
	"http://127.0.0.1:$PORT/id/not-an-object-id" || true)
if [ "$code" = 404 ]; then
	echo "  404, and no question asked of the database"
else
	note "code $code, expected 404"
fi

echo "--- a root collection that holds nothing ---"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
	"http://127.0.0.1:$PORT/other/$SMALL_ID" || true)
if [ "$code" = 404 ]; then
	echo "  404"
else
	note "code $code, expected 404"
fi

echo "--- the host:port form of the mongo directive ---"
code=$(curl -s -o "$WORK/out/host.bin" -w '%{http_code}' --max-time 20 \
	"http://127.0.0.1:$PORT/host/$SMALL_ID" || true)
if [ "$code" = 200 ] && cmp -s "$WORK/out/host.bin" "$MONGO_SMALL"; then
	echo "  the same file, through a URI built from host and port"
else
	note "code $code for the host:port form"
fi

echo "--- a method the module does not serve ---"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
	-X DELETE "http://127.0.0.1:$PORT/id/$SMALL_ID" || true)
if [ "$code" = 405 ]; then
	echo "  405"
else
	note "code $code, expected 405"
fi

echo "--- ten at once ---"
: > "$WORK/out/parallel.txt"
i=0
while [ "$i" -lt 10 ]; do
	curl -s -o "$WORK/out/p$i.bin" -w '%{http_code}\n' --max-time 60 \
		"http://127.0.0.1:$PORT/id/$LARGE_ID" >> "$WORK/out/parallel.txt" &
	i=$((i + 1))
done
wait
bad=$(grep -cv '^200$' "$WORK/out/parallel.txt" || true)
wrong=0
i=0
while [ "$i" -lt 10 ]; do
	cmp -s "$WORK/out/p$i.bin" "$MONGO_LARGE" || wrong=$((wrong + 1))
	i=$((i + 1))
done
if [ "$bad" -eq 0 ] && [ "$wrong" -eq 0 ]; then
	echo "  ten copies of the big file, all identical to it"
else
	note "$bad were not 200, $wrong differed"
fi

echo "--- a client that hangs up in the middle ---"
curl -s --max-time 0.1 "http://127.0.0.1:$PORT/id/$LARGE_ID" -o /dev/null \
	2>/dev/null || true
sleep 1
echo "  the worker is supposed to survive this, see the log check below"

echo "--- the worker is still there ---"
alive=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/alive" || true)
if [ "$alive" = alive ]; then
	echo "  it answers"
else
	note "the worker did not answer after all that"
fi

echo "--- nothing in the error log that should not be there ---"
if grep -E '\[alert\]|\[emerg\]|exited on signal' "$WORK/logs/error.log"; then
	note "the log carries an alert, an emerg or a worker that died"
else
	echo "  no alert, no emerg, no signal"
fi

if [ "$fail" -ne 0 ]; then
	echo >&2
	echo "--- the error log, last 40 lines ---" >&2
	tail -40 "$WORK/logs/error.log" >&2 2>/dev/null || true
fi

exit $fail
