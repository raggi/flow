require 'mkmf'

$defs << "-DRUBY_VERSION_CODE=#{RUBY_VERSION.gsub(/\D/, '')}"
$src = ["ebb_request_parser_ffi.c", "ebb_request_parser.c"]
dir_config("ebb_request_parser_ffi")
create_makefile('ebb_request_parser_ffi')
