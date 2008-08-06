require 'mkmf'

$defs << "-DRUBY_VERSION_CODE=#{RUBY_VERSION.gsub(/\D/, '')}"
dir_config("ebb_request_parser_ffi")
create_makefile('ebb_request_parser_ffi')
