require 'rubygems'
require 'rev'
require File.dirname(__FILE__) + "/lib/flow"

class App
  def call(env)
    body = "hello world"
    [200, {
      "content-type" => "text/plain",
      "content-length" => body.length.to_s
    }, [body]]
  end
end

evloop = Rev::Loop.default 
Flow.start_server(evloop, App.new)
evloop.run
