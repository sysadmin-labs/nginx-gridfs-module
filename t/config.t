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
# The request goes to the gridfs location, not past it.  Nothing listens on
# that port, so the answer is 503 -- which is the module saying it got as
# far as trying.  A request to some other location with a "return" in it
# would prove only that "return" works: a return fires in the rewrite phase
# and the content handler never runs.
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17099/?serverSelectionTimeoutMS=500;
        gridfs ngxtest field=filename type=string;
    }
--- request
GET /f/anything.txt
--- error_code: 503



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



=== TEST 9: a port that cannot be one
# The host is not resolved while the configuration is read -- a name that
# only exists in production has to be allowed -- so what can be refused
# here is the part that is wrong on its face.
--- config
    location /f/ {
        mongo 127.0.0.1:99999;
        gridfs ngxtest;
    }
--- must_die
--- error_log
invalid port



=== TEST 10: a connection URI is taken as it stands
# 503 rather than a served file: the URI was accepted, the pool was built
# from it, and the module went looking.  That the option in it is honoured
# is what makes this block quick -- with libmongoc's default of thirty
# seconds the request would sit there instead.
--- config
    location /f/ {
        mongo mongodb://127.0.0.1:17099/?serverSelectionTimeoutMS=500;
        gridfs ngxtest;
    }
--- request
GET /f/000000000000000000000001
--- error_code: 503



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
# What this proves is that the URI built from two hosts and a name --
# mongodb://host,host/db?replicaSet=rs0 -- is one libmongoc accepts, which
# is checked while the configuration is read: a URI it refuses stops nginx
# from starting, as TEST 11 shows.
#
# It deliberately does not ask the module for a file.  The URI built from
# words carries no serverSelectionTimeoutMS, so a request to a replica set
# that is not there would sit for libmongoc's default of thirty seconds --
# in the worker.  Only the "mongo <uri>" form can say otherwise, and that
# is TEST 10.
--- config
    location /f/ {
        mongo rs0 127.0.0.1:17098 127.0.0.1:17099;
        gridfs ngxtest;
    }
--- request
GET /nothing-here
--- error_code: 404
