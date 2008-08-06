/* copyright ryah dahl 2008 ry at tiny clouds dot org
 * all rights reserved
 */
#include <ruby.h>
#include <assert.h>
#include <ebb_request_parser.h>
#ifndef RSTRING_PTR
# define RSTRING_PTR(s) (RSTRING(s)->ptr)
# define RSTRING_LEN(s) (RSTRING(s)->len)
#endif

static char upcase[] =
  "\0______________________________"
  "_________________0123456789_____"
  "__ABCDEFGHIJKLMNOPQRSTUVWXYZ____"
  "__ABCDEFGHIJKLMNOPQRSTUVWXYZ____"
  "________________________________"
  "________________________________"
  "________________________________"
  "________________________________";

static VALUE cRequestParser;
static VALUE cRequest;
static VALUE cError;

/* g is for global */
static VALUE g_fragment;
static VALUE g_path_info;
static VALUE g_query_string;
static VALUE g_request_body;
static VALUE g_request_method;
static VALUE g_request_path;
static VALUE g_request_uri;
static VALUE g_server_port;
static VALUE g_content_length;
static VALUE g_content_type;
static VALUE g_http_client_ip;
static VALUE g_http_prefix;
static VALUE g_http_version;
static VALUE g_empty_str;

static VALUE g_COPY;
static VALUE g_DELETE;
static VALUE g_GET;
static VALUE g_HEAD;
static VALUE g_LOCK;
static VALUE g_MKCOL;
static VALUE g_MOVE;
static VALUE g_OPTIONS;
static VALUE g_POST;
static VALUE g_PROPFIND;
static VALUE g_PROPPATCH;
static VALUE g_PUT;
static VALUE g_TRACE;
static VALUE g_UNLOCK;

static VALUE request_keep_alive(VALUE rb_request) 
{
  ebb_request *request; 
  Data_Get_Struct(rb_request, ebb_request, request);
  return ebb_request_should_keep_alive(request) ? Qtrue : Qfalse;
}

#define APPEND_ENV(NAME) \
  VALUE rb_request = (VALUE)request->data;  \
  VALUE env = rb_iv_get(rb_request, "@env_ffi"); \
  VALUE v = rb_hash_aref(env, g_##NAME); \
  if(v == Qnil) \
    rb_hash_aset(env, g_##NAME, rb_str_new(at, len)); \
  else \
    rb_str_cat(v, at, len);

static void 
request_path(ebb_request *request, const char *at, size_t len)
{
  APPEND_ENV(request_path);
}

static void 
query_string(ebb_request *request, const char *at, size_t len)
{
  APPEND_ENV(query_string);
}

static void 
request_uri(ebb_request *request, const char *at, size_t len)
{
  APPEND_ENV(request_uri);
}

static void 
fragment(ebb_request *request, const char *at, size_t len)
{
  APPEND_ENV(fragment);
}

/* very ugly... */
static void 
header_field(ebb_request *request, const char *at, size_t len, int _)
{
  VALUE rb_request = (VALUE)request->data; 
  VALUE field = rb_iv_get(rb_request, "@field_in_progress");
  VALUE value = rb_iv_get(rb_request, "@value_in_progress");

  if( (field == Qnil && value == Qnil) || (field != Qnil && value != Qnil)) {
    if(field != Qnil) {
      VALUE env = rb_iv_get(rb_request, "@env_ffi");
      rb_hash_aset(env, field, value);
    }

    // prefix with HTTP_
    VALUE f = rb_str_new(NULL, RSTRING_LEN(g_http_prefix) + len);
    memcpy( RSTRING_PTR(f)
          , RSTRING_PTR(g_http_prefix)
          , RSTRING_LEN(g_http_prefix)
          );
    int i;
    // normalize
    for(i = 0; i < len; i++) {
      char *ch = RSTRING_PTR(f) + RSTRING_LEN(g_http_prefix) + i;
      *ch = upcase[(int)at[i]];
    }
    rb_iv_set(rb_request, "@field_in_progress", f);
    rb_iv_set(rb_request, "@value_in_progress", Qnil);

  } else if(field != Qnil) {
    // nth pass n!= 1
    rb_str_cat(field, at, len);

  } else {
    assert(0 && "field == Qnil && value != Qnil"); 
  }
}

static void 
header_value(ebb_request *request, const char *at, size_t len, int _)
{
  VALUE rb_request = (VALUE)request->data; 
  VALUE v = rb_iv_get(rb_request, "@value_in_progress");
  if(v == Qnil)
    rb_iv_set(rb_request, "@value_in_progress", rb_str_new(at, len));
  else
    rb_str_cat(v, at, len);
}

static void 
headers_complete(ebb_request *request)
{
  VALUE rb_request = (VALUE)request->data; 

  VALUE env = rb_iv_get(rb_request, "@env_ffi");

  rb_iv_set(rb_request, "@content_length", INT2FIX(request->content_length));
  rb_iv_set( rb_request
           , "@chunked"
           , request->transfer_encoding == EBB_CHUNKED ? Qtrue : Qfalse
           );

  /* set REQUEST_METHOD. yuck */
  VALUE method = Qnil;
  switch(request->method) {
    case EBB_COPY      : method = g_COPY      ; break;
    case EBB_DELETE    : method = g_DELETE    ; break;
    case EBB_GET       : method = g_GET       ; break;
    case EBB_HEAD      : method = g_HEAD      ; break;
    case EBB_LOCK      : method = g_LOCK      ; break;
    case EBB_MKCOL     : method = g_MKCOL     ; break;
    case EBB_MOVE      : method = g_MOVE      ; break;
    case EBB_OPTIONS   : method = g_OPTIONS   ; break;
    case EBB_POST      : method = g_POST      ; break;
    case EBB_PROPFIND  : method = g_PROPFIND  ; break;
    case EBB_PROPPATCH : method = g_PROPPATCH ; break;
    case EBB_PUT       : method = g_PUT       ; break;
    case EBB_TRACE     : method = g_TRACE     ; break;
    case EBB_UNLOCK    : method = g_UNLOCK    ; break;
  }
  rb_hash_aset(env, g_request_method, method);

  /* set PATH_INFO */
  rb_hash_aset(env, g_path_info, rb_hash_aref(env, g_request_path));

  /* set HTTP_VERSION */
  VALUE version = rb_str_buf_new(11);
  sprintf(RSTRING_PTR(version), "HTTP/%d.%d", request->version_major, request->version_minor);
#if RUBY_VERSION_CODE < 187
  RSTRING_LEN(version) = strlen(RSTRING_PTR(version));
#else
  rb_str_set_len(version, strlen(RSTRING_PTR(version)));
#endif
  rb_hash_aset(env, g_http_version, version);

  VALUE rb_parser = rb_iv_get(rb_request, "@parser");
  VALUE notifier = rb_iv_get(rb_parser, "@notifier");
  rb_funcall(notifier, rb_intern("on_request"), 1, rb_request);
}

static void 
body_handler(ebb_request *request, const char *at, size_t length)
{
  VALUE rb_request = (VALUE)request->data; 
  VALUE chunk = rb_str_new(at, length);
  rb_funcall(rb_request, rb_intern("on_body"), chunk);
}

static void 
request_complete(ebb_request *request)
{
  VALUE rb_request = (VALUE)request->data; 
  rb_iv_set(rb_request, "@body_complete", Qtrue);
}

static ebb_request* new_request(void *data)
{
  VALUE rb_parser = (VALUE)data;
  ebb_request *request = ALLOC(ebb_request);
  VALUE rb_request = Data_Wrap_Struct(cRequest, 0, xfree, request);
  ebb_request_init(request);
  request->on_path = request_path;
  request->on_query_string = query_string;
  request->on_uri = request_uri;
  request->on_fragment = fragment;
  request->on_header_field = header_field;
  request->on_header_value = header_value;
  request->on_headers_complete = headers_complete;
  request->on_body = body_handler;
  request->on_complete = request_complete;
  request->data = (void*)rb_request;

  rb_iv_set(rb_request, "@env_ffi", rb_hash_new());
  rb_iv_set(rb_request, "@parser", rb_parser);
  rb_iv_set(rb_request, "@body_complete", Qfalse);

  return request;
}

static VALUE request_parser_init(VALUE rb_parser, VALUE notifier)
{
  ebb_request_parser *parser; 
  Data_Get_Struct(rb_parser, ebb_request_parser, parser);
  ebb_request_parser_init(parser);
  parser->new_request = new_request;
  parser->data = (void*)rb_parser;

  rb_iv_set(rb_parser, "@notifier", notifier);
  return rb_parser;
}

static VALUE request_parser_alloc(VALUE _)
{
  ebb_request_parser *parser = malloc(sizeof(ebb_request_parser));
  VALUE rb_parser = Data_Wrap_Struct(cRequestParser, 0, xfree, parser);
  return rb_parser;
}

VALUE request_parser_execute(VALUE rb_parser, VALUE buf)
{
  ebb_request_parser *parser; 
  Data_Get_Struct(rb_parser, ebb_request_parser, parser);
  ebb_request_parser_execute(parser, RSTRING_PTR(buf), RSTRING_LEN(buf));
  if(ebb_request_parser_has_error(parser))
    rb_raise(cError, "http parse error");
  return Qnil;
}

void
Init_ebb_request_parser_ffi()
{
  VALUE mEbb = rb_define_module("Ebb");
  cRequestParser = rb_define_class_under(mEbb, "RequestParser", rb_cObject);
  cRequest = rb_define_class_under(cRequestParser, "Request", rb_cObject);
  cError = rb_define_class_under(cRequestParser, "Error", rb_eStandardError);

   
  rb_define_alloc_func(cRequestParser, request_parser_alloc);
  rb_define_method(cRequestParser, "initialize", request_parser_init, 1);
  rb_define_method(cRequestParser, "execute", request_parser_execute, 1);

  rb_define_method(cRequest, "keep_alive?", request_keep_alive, 0);
#define DEF_GLOBAL(N, val) g_##N = rb_obj_freeze(rb_str_new2(val)); rb_global_variable(&g_##N)
  DEF_GLOBAL(content_length, "CONTENT_LENGTH");
  DEF_GLOBAL(content_type, "CONTENT_TYPE");
  DEF_GLOBAL(fragment, "FRAGMENT");
  DEF_GLOBAL(path_info, "PATH_INFO");
  DEF_GLOBAL(query_string, "QUERY_STRING");
  DEF_GLOBAL(request_body, "REQUEST_BODY");
  DEF_GLOBAL(request_method, "REQUEST_METHOD");
  DEF_GLOBAL(request_path, "REQUEST_PATH");
  DEF_GLOBAL(request_uri, "REQUEST_URI");
  DEF_GLOBAL(server_port, "SERVER_PORT");
  DEF_GLOBAL(http_client_ip, "HTTP_CLIENT_IP");
  DEF_GLOBAL(http_prefix, "HTTP_");
  DEF_GLOBAL(http_version, "HTTP_VERSION");
  DEF_GLOBAL(empty_str, "");

  DEF_GLOBAL(COPY, "COPY");
  DEF_GLOBAL(DELETE, "DELETE");
  DEF_GLOBAL(GET, "GET");
  DEF_GLOBAL(HEAD, "HEAD");
  DEF_GLOBAL(LOCK, "LOCK");
  DEF_GLOBAL(MKCOL, "MKCOL");
  DEF_GLOBAL(MOVE, "MOVE");
  DEF_GLOBAL(OPTIONS, "OPTIONS");
  DEF_GLOBAL(POST, "POST");
  DEF_GLOBAL(PROPFIND, "PROPFIND");
  DEF_GLOBAL(PROPPATCH, "PROPPATCH");
  DEF_GLOBAL(PUT, "PUT");
  DEF_GLOBAL(TRACE, "TRACE");
  DEF_GLOBAL(UNLOCK, "UNLOCK");
 
}
