
require 'ext/ebb_request_parser_ffi'

class X
  def on_request
    puts "hllo"
  end
end


p = Ebb::RequestParser.new(X.new)
p.execute("hello world")
