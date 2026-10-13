/*
 * Copyright 2009-2010 Michael Dirolf
 *
 * Dual Licensed under the Apache License, Version 2.0 and the GNU
 * General Public License, version 2 or (at your option) any later
 * version.
 *
 * -- Apache License
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * -- GNU GPL
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

/*
 * The driver layer of this module was rewritten for libmongoc.  What it
 * replaces talked to the legacy mongo-c-driver, which this module carried
 * as a git submodule: that driver has not existed for years, the submodule
 * pointed at a git:// URL GitHub stopped serving in 2021, and the
 * directory it should have filled was empty.  Nothing here could be built
 * any more.
 *
 * libmongoc does by itself what roughly half of this file used to do by
 * hand -- connecting, reconnecting, authenticating, finding the primary of
 * a replica set, keeping connections for reuse -- all of it behind a
 * connection URI and a client pool.  The directives are unchanged, so a
 * configuration written for the old module needs no edit; the URI is built
 * from them.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

#include <mongoc/mongoc.h>


#define NGX_HTTP_GRIDFS_FIELD_ID          0
#define NGX_HTTP_GRIDFS_FIELD_FILENAME    1

#define NGX_HTTP_GRIDFS_TYPE_OID          0
#define NGX_HTTP_GRIDFS_TYPE_STRING       1
#define NGX_HTTP_GRIDFS_TYPE_INT          2

/* What a chunk read is given at most in one go, when the file does not say
 * what its chunk size is.  GridFS uses 255 KiB by default.
 */
#define NGX_HTTP_GRIDFS_CHUNK_SIZE        261120


typedef struct {
    ngx_str_t   host;
    in_port_t   port;
} ngx_http_gridfs_server_t;


typedef struct {
    ngx_str_t              db;
    ngx_str_t              root_collection;
    ngx_str_t              user;
    ngx_str_t              pass;
    ngx_str_t              replset;
    ngx_str_t              name;        /* the "mongo" directive, for messages */
    ngx_array_t           *servers;     /* ngx_http_gridfs_server_t */
    ngx_uint_t             field;
    ngx_uint_t             type;

    ngx_str_t              uri;         /* built from everything above */
    mongoc_client_pool_t  *pool;        /* per worker, see init_worker */
} ngx_http_gridfs_loc_conf_t;


typedef struct {
    ngx_array_t   loc_confs;            /* ngx_http_gridfs_loc_conf_t * */
} ngx_http_gridfs_main_conf_t;


static char *ngx_http_gridfs_mongo(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf);
static char *ngx_http_gridfs(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static void *ngx_http_gridfs_create_main_conf(ngx_conf_t *cf);
static void *ngx_http_gridfs_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_gridfs_merge_loc_conf(ngx_conf_t *cf, void *parent,
    void *child);
static ngx_int_t ngx_http_gridfs_build_uri(ngx_pool_t *pool,
    ngx_http_gridfs_loc_conf_t *glcf);
static ngx_int_t ngx_http_gridfs_init_worker(ngx_cycle_t *cycle);
static void ngx_http_gridfs_exit_worker(ngx_cycle_t *cycle);
static ngx_int_t ngx_http_gridfs_handler(ngx_http_request_t *r);


static ngx_command_t  ngx_http_gridfs_commands[] = {

    { ngx_string("mongo"),
      NGX_HTTP_LOC_CONF|NGX_CONF_1MORE,
      ngx_http_gridfs_mongo,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("gridfs"),
      NGX_HTTP_LOC_CONF|NGX_CONF_1MORE,
      ngx_http_gridfs,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_gridfs_module_ctx = {
    NULL,                                  /* preconfiguration */
    NULL,                                  /* postconfiguration */
    ngx_http_gridfs_create_main_conf,      /* create main configuration */
    NULL,                                  /* init main configuration */
    NULL,                                  /* create server configuration */
    NULL,                                  /* merge server configuration */
    ngx_http_gridfs_create_loc_conf,       /* create location configuration */
    ngx_http_gridfs_merge_loc_conf         /* merge location configuration */
};


ngx_module_t  ngx_http_gridfs_module = {
    NGX_MODULE_V1,
    &ngx_http_gridfs_module_ctx,           /* module context */
    ngx_http_gridfs_commands,              /* module directives */
    NGX_HTTP_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    ngx_http_gridfs_init_worker,           /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    ngx_http_gridfs_exit_worker,           /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};


static void *
ngx_http_gridfs_create_main_conf(ngx_conf_t *cf)
{
    ngx_http_gridfs_main_conf_t  *gmcf;

    gmcf = ngx_pcalloc(cf->pool, sizeof(ngx_http_gridfs_main_conf_t));
    if (gmcf == NULL) {
        return NULL;
    }

    /* Every location that ends up with a pool is listed here, because the
     * pools are made in the worker and the worker is handed the cycle and
     * nothing else.
     */
    if (ngx_array_init(&gmcf->loc_confs, cf->pool, 4,
                       sizeof(ngx_http_gridfs_loc_conf_t *))
        != NGX_OK)
    {
        return NULL;
    }

    return gmcf;
}


static void *
ngx_http_gridfs_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_gridfs_loc_conf_t  *glcf;

    glcf = ngx_pcalloc(cf->pool, sizeof(ngx_http_gridfs_loc_conf_t));
    if (glcf == NULL) {
        return NULL;
    }

    glcf->field = NGX_CONF_UNSET_UINT;
    glcf->type = NGX_CONF_UNSET_UINT;

    return glcf;
}


static char *
ngx_http_gridfs_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_gridfs_loc_conf_t  *prev = parent;
    ngx_http_gridfs_loc_conf_t  *conf = child;

    /* A location either has a gridfs directive of its own or has nothing to
     * do with this module: the directive is what installs the content
     * handler, so there is no inheriting half a configuration.
     */
    if (conf->db.len == 0) {
        return NGX_CONF_OK;
    }

    ngx_conf_merge_str_value(conf->root_collection, prev->root_collection,
                             "fs");
    ngx_conf_merge_uint_value(conf->field, prev->field,
                              NGX_HTTP_GRIDFS_FIELD_ID);
    ngx_conf_merge_uint_value(conf->type, prev->type,
                              NGX_HTTP_GRIDFS_TYPE_OID);

    if (conf->servers == NULL && conf->uri.len == 0) {
        conf->servers = prev->servers;
        conf->replset = prev->replset;
        conf->name = prev->name;
        conf->uri = prev->uri;
    }

    if (conf->user.len == 0) {
        conf->user = prev->user;
        conf->pass = prev->pass;
    }

    if (conf->field == NGX_HTTP_GRIDFS_FIELD_FILENAME
        && conf->type != NGX_HTTP_GRIDFS_TYPE_STRING)
    {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "\"gridfs\": field=filename needs type=string");
        return NGX_CONF_ERROR;
    }

    /* Everything a connection needs is decided here, while the
     * configuration is being read, and not in the worker.  By the time a
     * worker starts, nginx has daemonized and whoever started it has
     * already been told the start succeeded: a fault found down there is
     * written into a log nobody is watching, and nginx exits without
     * anybody being any the wiser.
     */
    if (conf->uri.len == 0) {

        if (conf->servers == NULL || conf->servers->nelts == 0) {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                               "gridfs: no \"mongo\" directive for database "
                               "\"%V\"", &conf->db);
            return NGX_CONF_ERROR;
        }

        if (ngx_http_gridfs_build_uri(cf->pool, conf) != NGX_OK) {
            return NGX_CONF_ERROR;
        }
    }

    {
        mongoc_uri_t  *uri;
        bson_error_t   error;

        uri = mongoc_uri_new_with_error((char *) conf->uri.data, &error);

        if (uri == NULL) {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                               "gridfs: cannot make sense of \"%V\": %s",
                               &conf->uri, error.message);
            return NGX_CONF_ERROR;
        }

        mongoc_uri_destroy(uri);
    }

    if (conf->field == NGX_HTTP_GRIDFS_FIELD_ID
        && conf->type == NGX_HTTP_GRIDFS_TYPE_STRING)
    {
        /* A string _id is a thing MongoDB allows, so this is not an error.
         * It is worth a word in the log, because the usual mistake is to
         * leave type= at its default of objectid and then wonder why
         * nothing is found.
         */
        ngx_conf_log_error(NGX_LOG_INFO, cf, 0,
                           "\"gridfs\": field=_id with type=string, looking "
                           "up string identifiers");
    }

    return NGX_CONF_OK;
}


/* "mongo [<replica set>] <host>[:<port>] ..."
 *
 * One host is a single server.  More than one means a replica set, and then
 * the first word is its name -- which is how the directive has always been
 * read, and libmongoc wants that name too, as ?replicaSet= in the URI.
 */
static char *
ngx_http_gridfs_mongo(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_gridfs_loc_conf_t  *glcf = conf;
    ngx_http_gridfs_server_t    *server;
    ngx_str_t                   *value;
    ngx_url_t                    u;
    ngx_uint_t                   i, start;

    value = cf->args->elts;

    if (glcf->servers != NULL || glcf->uri.len != 0) {
        return "is duplicate";
    }

    glcf->name = value[1];

    /* A connection URI is taken as it stands.  Everything the driver can be
     * told lives in there -- the server selection timeout, TLS, the
     * authentication source, read preferences -- and none of it has a
     * directive here.  Without this the only way to reach any of it would
     * be a new directive per option.
     */
    if (cf->args->nelts == 2
        && (ngx_strncasecmp(value[1].data, (u_char *) "mongodb://",
                            sizeof("mongodb://") - 1) == 0
            || ngx_strncasecmp(value[1].data, (u_char *) "mongodb+srv://",
                               sizeof("mongodb+srv://") - 1) == 0))
    {
        glcf->uri = value[1];
        return NGX_CONF_OK;
    }

    glcf->servers = ngx_array_create(cf->pool, cf->args->nelts,
                                     sizeof(ngx_http_gridfs_server_t));
    if (glcf->servers == NULL) {
        return NGX_CONF_ERROR;
    }

    if (cf->args->nelts >= 3) {
        glcf->replset = value[1];
        start = 2;

    } else {
        start = 1;
    }

    for (i = start; i < cf->args->nelts; i++) {

        ngx_memzero(&u, sizeof(ngx_url_t));

        u.url = value[i];
        u.default_port = 27017;
        u.no_resolve = 1;

        if (ngx_parse_url(cf->pool, &u) != NGX_OK) {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                               "\"mongo\": %s in \"%V\"",
                               u.err ? u.err : "invalid address", &value[i]);
            return NGX_CONF_ERROR;
        }

        server = ngx_array_push(glcf->servers);
        if (server == NULL) {
            return NGX_CONF_ERROR;
        }

        server->host = u.host;
        server->port = (in_port_t) u.port;
    }

    if (glcf->servers->nelts == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "\"mongo\": no server given");
        return NGX_CONF_ERROR;
    }

    return NGX_CONF_OK;
}


/* "gridfs <db> [root_collection=] [field=] [type=] [user=] [pass=]" */
static char *
ngx_http_gridfs(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_gridfs_loc_conf_t   *glcf = conf;
    ngx_http_gridfs_loc_conf_t  **slot;
    ngx_http_gridfs_main_conf_t  *gmcf;
    ngx_http_core_loc_conf_t     *clcf;
    ngx_str_t                    *value, arg;
    ngx_uint_t                    i;

    value = cf->args->elts;

    if (glcf->db.len != 0) {
        return "is duplicate";
    }

    glcf->db = value[1];

    for (i = 2; i < cf->args->nelts; i++) {

        if (ngx_strncmp(value[i].data, "root_collection=", 16) == 0) {
            glcf->root_collection.data = value[i].data + 16;
            glcf->root_collection.len = value[i].len - 16;
            continue;
        }

        if (ngx_strncmp(value[i].data, "field=", 6) == 0) {
            arg.data = value[i].data + 6;
            arg.len = value[i].len - 6;

            if (arg.len == sizeof("_id") - 1
                && ngx_strncmp(arg.data, "_id", arg.len) == 0)
            {
                glcf->field = NGX_HTTP_GRIDFS_FIELD_ID;

            } else if (arg.len == sizeof("filename") - 1
                       && ngx_strncmp(arg.data, "filename", arg.len) == 0)
            {
                glcf->field = NGX_HTTP_GRIDFS_FIELD_FILENAME;

            } else {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "\"gridfs\": unsupported field \"%V\", "
                                   "\"_id\" or \"filename\" expected", &arg);
                return NGX_CONF_ERROR;
            }

            continue;
        }

        if (ngx_strncmp(value[i].data, "type=", 5) == 0) {
            arg.data = value[i].data + 5;
            arg.len = value[i].len - 5;

            if (arg.len == sizeof("objectid") - 1
                && ngx_strncasecmp(arg.data, (u_char *) "objectid", arg.len)
                   == 0)
            {
                glcf->type = NGX_HTTP_GRIDFS_TYPE_OID;

            } else if (arg.len == sizeof("string") - 1
                       && ngx_strncasecmp(arg.data, (u_char *) "string",
                                          arg.len) == 0)
            {
                glcf->type = NGX_HTTP_GRIDFS_TYPE_STRING;

            } else if (arg.len == sizeof("int") - 1
                       && ngx_strncasecmp(arg.data, (u_char *) "int", arg.len)
                          == 0)
            {
                glcf->type = NGX_HTTP_GRIDFS_TYPE_INT;

            } else {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "\"gridfs\": unsupported type \"%V\", "
                                   "\"objectid\", \"string\" or \"int\" "
                                   "expected", &arg);
                return NGX_CONF_ERROR;
            }

            continue;
        }

        if (ngx_strncmp(value[i].data, "user=", 5) == 0) {
            glcf->user.data = value[i].data + 5;
            glcf->user.len = value[i].len - 5;
            continue;
        }

        if (ngx_strncmp(value[i].data, "pass=", 5) == 0) {
            glcf->pass.data = value[i].data + 5;
            glcf->pass.len = value[i].len - 5;
            continue;
        }

        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "\"gridfs\": invalid parameter \"%V\"", &value[i]);
        return NGX_CONF_ERROR;
    }

    gmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_gridfs_module);

    slot = ngx_array_push(&gmcf->loc_confs);
    if (slot == NULL) {
        return NGX_CONF_ERROR;
    }
    *slot = glcf;

    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_gridfs_handler;

    return NGX_CONF_OK;
}


/* mongodb://[user:pass@]host[:port][,host[:port]...]/db[?replicaSet=name]
 *
 * Built once, in the worker, because libmongoc wants a URI and this module's
 * directives are older than that convention.  user and pass are percent
 * encoded: a password with an @ or a / in it would otherwise end the
 * userinfo or the host part early, and the failure would look like a
 * connection problem rather than a quoting one.
 */
static ngx_int_t
ngx_http_gridfs_build_uri(ngx_pool_t *pool,
    ngx_http_gridfs_loc_conf_t *glcf)
{
    ngx_http_gridfs_server_t  *server;
    size_t                     len;
    u_char                    *p;
    ngx_uint_t                 i;
    uintptr_t                  euser, epass, ereplset;

    static ngx_str_t  scheme = ngx_string("mongodb://");

    server = glcf->servers->elts;

    euser = ngx_escape_uri(NULL, glcf->user.data, glcf->user.len,
                           NGX_ESCAPE_URI_COMPONENT);
    epass = ngx_escape_uri(NULL, glcf->pass.data, glcf->pass.len,
                           NGX_ESCAPE_URI_COMPONENT);
    ereplset = ngx_escape_uri(NULL, glcf->replset.data, glcf->replset.len,
                              NGX_ESCAPE_URI_COMPONENT);

    len = scheme.len + 1 /* '/' */ + glcf->db.len + 1 /* '\0' */;

    if (glcf->user.len) {
        len += glcf->user.len + 2 * euser + 1 /* ':' */
               + glcf->pass.len + 2 * epass + 1 /* '@' */;
    }

    for (i = 0; i < glcf->servers->nelts; i++) {
        /* host:port, and a comma between them */
        len += server[i].host.len + 1 + sizeof("65535") - 1 + 1;
    }

    if (glcf->replset.len) {
        len += sizeof("?replicaSet=") - 1 + glcf->replset.len + 2 * ereplset;
    }

    glcf->uri.data = ngx_pnalloc(pool, len);
    if (glcf->uri.data == NULL) {
        return NGX_ERROR;
    }

    p = ngx_copy(glcf->uri.data, scheme.data, scheme.len);

    if (glcf->user.len) {
        p = (u_char *) ngx_escape_uri(p, glcf->user.data, glcf->user.len,
                                      NGX_ESCAPE_URI_COMPONENT);
        *p++ = ':';
        p = (u_char *) ngx_escape_uri(p, glcf->pass.data, glcf->pass.len,
                                      NGX_ESCAPE_URI_COMPONENT);
        *p++ = '@';
    }

    for (i = 0; i < glcf->servers->nelts; i++) {
        if (i) {
            *p++ = ',';
        }
        p = ngx_sprintf(p, "%V:%d", &server[i].host, server[i].port);
    }

    *p++ = '/';
    p = ngx_copy(p, glcf->db.data, glcf->db.len);

    if (glcf->replset.len) {
        p = ngx_copy(p, "?replicaSet=", sizeof("?replicaSet=") - 1);
        p = (u_char *) ngx_escape_uri(p, glcf->replset.data,
                                      glcf->replset.len,
                                      NGX_ESCAPE_URI_COMPONENT);
    }

    *p = '\0';
    glcf->uri.len = p - glcf->uri.data;

    return NGX_OK;
}


static ngx_int_t
ngx_http_gridfs_init_worker(ngx_cycle_t *cycle)
{
    ngx_http_gridfs_main_conf_t   *gmcf;
    ngx_http_gridfs_loc_conf_t   **glcfp;
    mongoc_uri_t                  *uri;
    bson_error_t                   error;
    ngx_uint_t                     i;

    gmcf = ngx_http_cycle_get_module_main_conf(cycle, ngx_http_gridfs_module);

    if (gmcf == NULL || gmcf->loc_confs.nelts == 0) {
        return NGX_OK;
    }

    /* Once per process, and before anything else in libmongoc is touched;
     * mongoc_client_pool_new_with_error() refuses to work otherwise and
     * says so.
     */
    mongoc_init();

    glcfp = gmcf->loc_confs.elts;

    for (i = 0; i < gmcf->loc_confs.nelts; i++) {

        /* The URI was built and checked while the configuration was read,
         * see ngx_http_gridfs_merge_loc_conf().
         */
        uri = mongoc_uri_new_with_error((char *) glcfp[i]->uri.data, &error);
        if (uri == NULL) {
            ngx_log_error(NGX_LOG_EMERG, cycle->log, 0,
                          "gridfs: cannot make sense of \"%V\": %s",
                          &glcfp[i]->uri, error.message);
            return NGX_ERROR;
        }

        glcfp[i]->pool = mongoc_client_pool_new_with_error(uri, &error);

        /* The pool keeps a copy of its own, so this one goes back. */
        mongoc_uri_destroy(uri);

        if (glcfp[i]->pool == NULL) {
            ngx_log_error(NGX_LOG_EMERG, cycle->log, 0,
                          "gridfs: cannot open a connection pool for \"%V\": "
                          "%s", &glcfp[i]->uri, error.message);
            return NGX_ERROR;
        }

        ngx_log_debug1(NGX_LOG_DEBUG_HTTP, cycle->log, 0,
                       "gridfs: pool for \"%V\"", &glcfp[i]->uri);
    }

    return NGX_OK;
}


static void
ngx_http_gridfs_exit_worker(ngx_cycle_t *cycle)
{
    ngx_http_gridfs_main_conf_t   *gmcf;
    ngx_http_gridfs_loc_conf_t   **glcfp;
    ngx_uint_t                     i;
    ngx_uint_t                     any = 0;

    gmcf = ngx_http_cycle_get_module_main_conf(cycle, ngx_http_gridfs_module);

    if (gmcf == NULL) {
        return;
    }

    glcfp = gmcf->loc_confs.elts;

    for (i = 0; i < gmcf->loc_confs.nelts; i++) {
        if (glcfp[i]->pool != NULL) {
            mongoc_client_pool_destroy(glcfp[i]->pool);
            glcfp[i]->pool = NULL;
            any = 1;
        }
    }

    /* Only when something was initialised: mongoc_cleanup() after a
     * mongoc_init() that never happened is not something to rely on.
     */
    if (any) {
        mongoc_cleanup();
    }
}


/* One byte range, which is what a file server is asked for in practice --
 * a media player seeking, or a download being resumed.
 *
 * Returns NGX_OK with start and end filled in, NGX_DECLINED for "send the
 * whole thing" (no Range header, or one this does not handle, which a
 * server is allowed to ignore), or 416 for a range that cannot be answered.
 *
 * Several ranges in one header are deliberately not handled: answering
 * those means a multipart/byteranges body, and a GridFS file is read from
 * the far end of a network to build it.  nginx's own range filter is not
 * used either, because it would have the whole file read out of the
 * database first and then throw most of it away.
 */
static ngx_int_t
ngx_http_gridfs_range(ngx_http_request_t *r, int64_t length, int64_t *start,
    int64_t *end)
{
    u_char     *p, *last, *dash;
    ngx_str_t   value;
    off_t       first, suffix;

    if (r->headers_in.range == NULL || length == 0) {
        return NGX_DECLINED;
    }

    value = r->headers_in.range->value;

    if (value.len < sizeof("bytes=-") - 1
        || ngx_strncasecmp(value.data, (u_char *) "bytes=",
                           sizeof("bytes=") - 1) != 0)
    {
        return NGX_DECLINED;
    }

    p = value.data + sizeof("bytes=") - 1;
    last = value.data + value.len;

    if (memchr(p, ',', last - p) != NULL) {
        /* more than one range */
        return NGX_DECLINED;
    }

    dash = memchr(p, '-', last - p);
    if (dash == NULL) {
        return NGX_DECLINED;
    }

    if (dash == p) {
        /* "bytes=-500": the last 500 bytes */
        if (dash + 1 == last) {
            return NGX_DECLINED;
        }

        suffix = ngx_atoof(dash + 1, last - dash - 1);
        if (suffix == NGX_ERROR || suffix == 0) {
            return NGX_HTTP_RANGE_NOT_SATISFIABLE;
        }

        if (suffix > length) {
            suffix = length;
        }

        *start = length - suffix;
        *end = length - 1;

        return NGX_OK;
    }

    first = ngx_atoof(p, dash - p);
    if (first == NGX_ERROR) {
        return NGX_DECLINED;
    }

    if (first >= length) {
        return NGX_HTTP_RANGE_NOT_SATISFIABLE;
    }

    *start = first;

    if (dash + 1 == last) {
        /* "bytes=500-": from there to the end */
        *end = length - 1;
        return NGX_OK;
    }

    first = ngx_atoof(dash + 1, last - dash - 1);
    if (first == NGX_ERROR) {
        return NGX_DECLINED;
    }

    if (first < *start) {
        return NGX_HTTP_RANGE_NOT_SATISFIABLE;
    }

    *end = (first >= length) ? length - 1 : first;

    return NGX_OK;
}


static ngx_int_t
ngx_http_gridfs_handler(ngx_http_request_t *r)
{
    ngx_http_gridfs_loc_conf_t  *glcf;
    ngx_http_core_loc_conf_t    *clcf;
    mongoc_client_t             *client;
    mongoc_gridfs_t             *gfs;
    mongoc_gridfs_file_t        *file;
    mongoc_iovec_t               iov;
    bson_t                       filter;
    bson_oid_t                   oid;
    bson_error_t                 error;
    ngx_str_t                    key;
    ngx_chain_t                  out;
    ngx_buf_t                   *b;
    ngx_int_t                    rc, n;
    const char                  *field, *content_type, *md5;
    int64_t                      length, start, end, remaining, upload_date;
    int32_t                      chunk_size;
    ssize_t                      got;
    u_char                      *dst, *src;

    glcf = ngx_http_get_module_loc_conf(r, ngx_http_gridfs_module);
    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);

    if (!(r->method & (NGX_HTTP_GET|NGX_HTTP_HEAD))) {
        return NGX_HTTP_NOT_ALLOWED;
    }

    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) {
        return rc;
    }

    if (glcf->pool == NULL) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "gridfs: no connection pool for database \"%V\"",
                      &glcf->db);
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    /* The key is what follows the location, unescaped: a filename may
     * contain a space, and an identifier may not contain a %.
     */
    if (r->uri.len <= clcf->name.len) {
        return NGX_HTTP_NOT_FOUND;
    }

    key.len = r->uri.len - clcf->name.len;

    key.data = ngx_pnalloc(r->pool, key.len + 1);
    if (key.data == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    dst = key.data;
    src = r->uri.data + clcf->name.len;
    ngx_unescape_uri(&dst, &src, key.len, 0);
    *dst = '\0';
    key.len = dst - key.data;

    if (key.len == 0) {
        return NGX_HTTP_NOT_FOUND;
    }

    field = (glcf->field == NGX_HTTP_GRIDFS_FIELD_FILENAME)
            ? "filename" : "_id";

    bson_init(&filter);

    switch (glcf->type) {

    case NGX_HTTP_GRIDFS_TYPE_OID:
        if (!bson_oid_is_valid((char *) key.data, key.len)) {
            /* Not an object id, so no object has it.  Answering 404 rather
             * than 500: what arrived is a request for something that cannot
             * exist, not a fault of this server's.
             */
            ngx_log_debug1(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                           "gridfs: \"%V\" is not an object id", &key);
            bson_destroy(&filter);
            return NGX_HTTP_NOT_FOUND;
        }

        bson_oid_init_from_string(&oid, (char *) key.data);
        BSON_APPEND_OID(&filter, field, &oid);
        break;

    case NGX_HTTP_GRIDFS_TYPE_INT:
        n = ngx_atoi(key.data, key.len);
        if (n == NGX_ERROR) {
            ngx_log_debug1(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                           "gridfs: \"%V\" is not a number", &key);
            bson_destroy(&filter);
            return NGX_HTTP_NOT_FOUND;
        }

        /* int64, which also matches a value stored as int32: MongoDB
         * compares numbers across those two types.
         */
        BSON_APPEND_INT64(&filter, field, (int64_t) n);
        break;

    default: /* NGX_HTTP_GRIDFS_TYPE_STRING */
        BSON_APPEND_UTF8(&filter, field, (char *) key.data);
        break;
    }

    client = mongoc_client_pool_pop(glcf->pool);

    gfs = mongoc_client_get_gridfs(client, (char *) glcf->db.data,
                                   (char *) glcf->root_collection.data,
                                   &error);
    if (gfs == NULL) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "gridfs: cannot reach \"%V\" in \"%V\": %s",
                      &glcf->root_collection, &glcf->db, error.message);
        bson_destroy(&filter);
        mongoc_client_pool_push(glcf->pool, client);
        return NGX_HTTP_SERVICE_UNAVAILABLE;
    }

    file = mongoc_gridfs_find_one_with_opts(gfs, &filter, NULL, &error);

    bson_destroy(&filter);

    if (file == NULL) {
        /* An empty message means the query worked and matched nothing. */
        if (error.message[0] != '\0') {
            ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                          "gridfs: looking for %s \"%V\" failed: %s",
                          field, &key, error.message);
            rc = NGX_HTTP_SERVICE_UNAVAILABLE;

        } else {
            ngx_log_debug2(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                           "gridfs: no file with %s \"%V\"", field, &key);
            rc = NGX_HTTP_NOT_FOUND;
        }

        mongoc_gridfs_destroy(gfs);
        mongoc_client_pool_push(glcf->pool, client);
        return rc;
    }

    length = mongoc_gridfs_file_get_length(file);
    chunk_size = mongoc_gridfs_file_get_chunk_size(file);
    content_type = mongoc_gridfs_file_get_content_type(file);
    md5 = mongoc_gridfs_file_get_md5(file);
    upload_date = mongoc_gridfs_file_get_upload_date(file);

    if (chunk_size <= 0) {
        chunk_size = NGX_HTTP_GRIDFS_CHUNK_SIZE;
    }

    start = 0;
    end = (length > 0) ? length - 1 : 0;

    rc = ngx_http_gridfs_range(r, length, &start, &end);

    if (rc == NGX_HTTP_RANGE_NOT_SATISFIABLE) {
        r->headers_out.status = NGX_HTTP_RANGE_NOT_SATISFIABLE;
        r->headers_out.content_length_n = 0;
        r->headers_out.content_range = ngx_list_push(&r->headers_out.headers);

        if (r->headers_out.content_range == NULL) {
            rc = NGX_HTTP_INTERNAL_SERVER_ERROR;
            goto done;
        }

        r->headers_out.content_range->hash = 1;
        ngx_str_set(&r->headers_out.content_range->key, "Content-Range");

        r->headers_out.content_range->value.data =
            ngx_pnalloc(r->pool, sizeof("bytes */") - 1 + NGX_OFF_T_LEN);
        if (r->headers_out.content_range->value.data == NULL) {
            rc = NGX_HTTP_INTERNAL_SERVER_ERROR;
            goto done;
        }

        r->headers_out.content_range->value.len =
            ngx_sprintf(r->headers_out.content_range->value.data,
                        "bytes */%O", (off_t) length)
            - r->headers_out.content_range->value.data;

        rc = ngx_http_send_header(r);
        if (rc == NGX_ERROR || rc > NGX_OK) {
            goto done;
        }

        rc = ngx_http_send_special(r, NGX_HTTP_LAST);
        goto done;
    }

    if (rc == NGX_OK) {
        r->headers_out.status = NGX_HTTP_PARTIAL_CONTENT;
        r->headers_out.content_length_n = end - start + 1;

        r->headers_out.content_range = ngx_list_push(&r->headers_out.headers);
        if (r->headers_out.content_range == NULL) {
            rc = NGX_HTTP_INTERNAL_SERVER_ERROR;
            goto done;
        }

        r->headers_out.content_range->hash = 1;
        ngx_str_set(&r->headers_out.content_range->key, "Content-Range");

        r->headers_out.content_range->value.data =
            ngx_pnalloc(r->pool,
                        sizeof("bytes -/") - 1 + 3 * NGX_OFF_T_LEN);
        if (r->headers_out.content_range->value.data == NULL) {
            rc = NGX_HTTP_INTERNAL_SERVER_ERROR;
            goto done;
        }

        r->headers_out.content_range->value.len =
            ngx_sprintf(r->headers_out.content_range->value.data,
                        "bytes %O-%O/%O", (off_t) start, (off_t) end,
                        (off_t) length)
            - r->headers_out.content_range->value.data;

    } else {
        r->headers_out.status = NGX_HTTP_OK;
        r->headers_out.content_length_n = length;
        start = 0;
        end = (length > 0) ? length - 1 : -1;
    }

    if (content_type != NULL && *content_type != '\0') {
        r->headers_out.content_type.len = ngx_strlen(content_type);
        r->headers_out.content_type.data = (u_char *) content_type;
        r->headers_out.content_type_lowcase = NULL;

    } else {
        r->headers_out.content_type = clcf->default_type;
        r->headers_out.content_type_lowcase = NULL;
    }
    r->headers_out.content_type_len = r->headers_out.content_type.len;

    /* GridFS keeps the upload time in milliseconds. */
    if (upload_date > 0) {
        r->headers_out.last_modified_time = (time_t) (upload_date / 1000);
    }

    /* The md5 of a GridFS file is not required any more -- it was taken out
     * of the specification in 2019 -- so a file written by a recent driver
     * may not have one, and then there is nothing to make an ETag from.
     */
    if (md5 != NULL && *md5 != '\0') {
        r->headers_out.etag = ngx_list_push(&r->headers_out.headers);
        if (r->headers_out.etag == NULL) {
            rc = NGX_HTTP_INTERNAL_SERVER_ERROR;
            goto done;
        }

        r->headers_out.etag->hash = 1;
        ngx_str_set(&r->headers_out.etag->key, "ETag");

        r->headers_out.etag->value.len = ngx_strlen(md5) + 2;
        r->headers_out.etag->value.data = ngx_pnalloc(r->pool,
                                              r->headers_out.etag->value.len);
        if (r->headers_out.etag->value.data == NULL) {
            rc = NGX_HTTP_INTERNAL_SERVER_ERROR;
            goto done;
        }

        ngx_sprintf(r->headers_out.etag->value.data, "\"%s\"", md5);
    }

    rc = ngx_http_send_header(r);

    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        goto done;
    }

    if (length == 0 || end < start) {
        rc = ngx_http_send_special(r, NGX_HTTP_LAST);
        goto done;
    }

    if (start != 0
        && mongoc_gridfs_file_seek(file, start, SEEK_SET) != 0)
    {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "gridfs: cannot seek to %O in %s \"%V\"",
                      (off_t) start, field, &key);
        rc = NGX_ERROR;
        goto done;
    }

    remaining = end - start + 1;

    /* One buffer per chunk, sent as soon as it is read, so that a client
     * starts receiving before the whole file has been fetched.  A request
     * still holds as much pool memory as the part of the file it asks for:
     * the buffers cannot be reused, because the filter chain below may
     * still be holding one that the client has not taken yet.  GridFS is
     * for files that fit.
     */
    while (remaining > 0) {

        n = (remaining < (int64_t) chunk_size) ? (ngx_int_t) remaining
                                              : (ngx_int_t) chunk_size;

        b = ngx_create_temp_buf(r->pool, n);
        if (b == NULL) {
            rc = NGX_ERROR;
            goto done;
        }

        iov.iov_base = b->last;
        iov.iov_len = (size_t) n;

        /* min_bytes is the whole buffer: a short read here would leave a
         * hole in the middle of the body.
         */
        got = mongoc_gridfs_file_readv(file, &iov, 1, (size_t) n, 0);

        if (got <= 0) {
            if (mongoc_gridfs_file_error(file, &error)) {
                ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                              "gridfs: reading %s \"%V\" failed: %s",
                              field, &key, error.message);
            } else {
                ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                              "gridfs: %s \"%V\" ended after %O of %O bytes",
                              field, &key, (off_t) (end - start + 1 - remaining),
                              (off_t) (end - start + 1));
            }

            rc = NGX_ERROR;
            goto done;
        }

        b->last += got;
        b->memory = 1;
        remaining -= got;

        b->last_buf = (remaining == 0) ? 1 : 0;
        b->last_in_chain = b->last_buf;

        /* Every chunk is flushed, not just the last one: the next one is a
         * round trip to the database away, so there is nothing to be gained
         * by holding this one back.
         */
        b->flush = 1;

        out.buf = b;
        out.next = NULL;

        rc = ngx_http_output_filter(r, &out);

        if (rc == NGX_ERROR || rc > NGX_OK) {
            goto done;
        }
    }

    rc = NGX_OK;

done:

    mongoc_gridfs_file_destroy(file);
    mongoc_gridfs_destroy(gfs);
    mongoc_client_pool_push(glcf->pool, client);

    return rc;
}
