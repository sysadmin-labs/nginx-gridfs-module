# vi:ft=perl
#
# What a request gets when the key cannot name a file, or the method is one
# this module does not serve.  None of these blocks needs a database either:
# a key that is not an object id is refused before anything is asked of
# MongoDB, which is both the faster answer and the one that does not depend
# on a server being up.
#
# The one case that does reach out -- nothing listening on the port -- uses a
# URI with a short server selection timeout, because libmongoc waits thirty
# seconds by default and it waits in the worker.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: a key that is not an object id
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17017/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=_id type=objectid;
    }
--- request
GET /f/not-an-object-id
--- error_code: 404
--- no_error_log
[alert]
[emerg]



=== TEST 2: an object id of the right length but not hexadecimal
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17017/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=_id type=objectid;
    }
--- request
GET /f/zzzzzzzzzzzzzzzzzzzzzzzz
--- error_code: 404



=== TEST 3: nothing after the location
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17017/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=_id type=objectid;
    }
--- request
GET /f/
--- error_code: 404



=== TEST 4: type=int with something that is not a number
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17017/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=_id type=int;
    }
--- request
GET /f/twelve
--- error_code: 404



=== TEST 5: a method this module does not serve
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17017/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=_id type=objectid;
    }
--- request
DELETE /f/000000000000000000000001
--- error_code: 405



=== TEST 6: POST, with a body to discard
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17017/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=_id type=objectid;
    }
--- request
POST /f/000000000000000000000001
a body that goes nowhere
--- error_code: 405



=== TEST 7: nothing listening where the configuration points
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17099/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=_id type=objectid;
    }
--- request
GET /f/000000000000000000000001
--- error_code: 503
--- error_log
gridfs:
--- no_error_log
[alert]



=== TEST 8: an escaped key is unescaped first
# A filename may hold a space, and the key comes out of the URI, so it
# arrives escaped.  With nothing listening the answer is 503 either way --
# what this block is about is that the module got as far as asking.
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17099/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=filename type=string;
    }
--- request
GET /f/two%20words.txt
--- error_code: 503
