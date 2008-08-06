require 'rake'
require 'rake/testtask'
require 'rake/gempackagetask'
require 'rake/clean'

SRC = ["ext/ebb_request_parser.h", "ext/ebb_request_parser.c", "ext/ebb_request_parser_ffi.c"]
CLEAN.add ["**/*.{o,bundle,so,obj,pdb,lib,def,exp}"]
CLOBBER.add ['ext/Makefile', 'ext/mkmf.log']

task(:default => [:compile])

task :compile => ['ext/Makefile']+SRC do
  sh "cd ext && make"
end

file('ext/Makefile' => 'ext/extconf.rb') do
  sh "cd ext && ruby extconf.rb"
end

file "ext/ebb_request_parser.c" => "ext/ebb_request_parser.rl" do
  sh 'ragel -s -G2 ext/ebb_request_parser.rl'
end
