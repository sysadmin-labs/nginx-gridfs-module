# vi:ft=perl
#
# What is refused while the configuration is read.  None of this needs a
# MongoDB: it is all decided before a request arrives, which is the point --
# a configuration that cannot mean anything should not wait for traffic to
# say so.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: a field this module cannot look up
--- config
    location /f/ {
        mongo 127.0.0.1:17017;
        gridfs ngxtest field=uploadDate;
    }
--- must_die
--- error_log
unsupported field "uploadDate"



=== TEST 2: a type this module does not know
--- config
    location /f/ {
        mongo 127.0.0.1:17017;
        gridfs ngxtest type=uuid;
    }
--- must_die
--- error_log
unsupported type "uuid"



=== TEST 3: a parameter that is none of them
--- config
    location /f/ {
        mongo 127.0.0.1:17017;
        gridfs ngxtest collection=fs;
    }
--- must_die
--- error_log
invalid parameter "collection=fs"



=== TEST 4: field=filename needs type=string
# A filename is a string, and the default type is objectid, so this pair is
# the one everybody writes first.
--- config
    location /f/ {
        mongo 127.0.0.1:17017;
        gridfs ngxtest field=filename;
    }
--- must_die
--- error_log
field=filename needs type=string



=== TEST 5: field=filename with type=string
--- config
    location /f/ {
        mongo 127.0.0.1:17017;
        gridfs ngxtest field=filename type=string;
    }
    location = /t {
        return 200 'served';
    }
--- request
GET /t
--- response_body chop
served



=== TEST 6: two gridfs directives in one location
--- config
    location /f/ {
        mongo 127.0.0.1:17017;
        gridfs ngxtest;
        gridfs other;
    }
--- must_die
--- error_log
"gridfs" directive is duplicate



=== TEST 7: two mongo directives in one location
--- config
    location /f/ {
        mongo 127.0.0.1:17017;
        mongo 127.0.0.2:17017;
        gridfs ngxtest;
    }
--- must_die
--- error_log
"mongo" directive is duplicate



=== TEST 8: gridfs without mongo
# The database to read is in one directive and the server to read it from is
# in the other, so one without the other cannot work.  It is refused when
# the worker starts, which is as early as this can be noticed: nothing is
# resolved while the configuration is being read.
--- config
    location /f/ {
        gridfs ngxtest;
    }
--- must_die
--- error_log
no "mongo" directive for database "ngxtest"



=== TEST 9: an address that is not one
--- config
    location /f/ {
        mongo "not a host";
        gridfs ngxtest;
    }
--- must_die



=== TEST 10: a connection URI is taken as it stands
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17017/?serverSelectionTimeoutMS=500;
        gridfs ngxtest;
    }
    location = /t {
        return 200 'served';
    }
--- request
GET /t
--- response_body chop
served



=== TEST 11: a URI the driver refuses
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17017/?serverSelectionTimeoutMS=banana;
        gridfs ngxtest;
    }
--- must_die
--- error_log
cannot make sense of



=== TEST 12: a replica set, which is three words
--- config
    location /f/ {
        mongo rs0 127.0.0.1:17017 127.0.0.1:17018;
        gridfs ngxtest;
    }
    location = /t {
        return 200 'served';
    }
--- request
GET /t
--- response_body chop
served
