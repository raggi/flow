require 'rubygems'
require 'rev'
require File.dirname(__FILE__) + "/lib/flow"


class DeferredBody
  def call(chunk)
    @callback.call(chunk)
  end

  def each(&block)
    @callback = block
  end
end

class Delay < Rev::TimerWatcher
  def self.create(evloop, seconds, &block)
    d = new(seconds, &block)
    d.attach(evloop)
    d
  end

  def initialize(seconds, &block)
    @block = block
    super(seconds, false)
  end

  def on_timer
    detach
    @block.call
  end

end

class App
  def initialize(evloop)
    @evloop = evloop
  end
  
  def call(env)
    body = DeferredBody.new 

    Delay.create(@evloop, 0.5) do 
      env['async.callback'].call(
          200, 
          { "content-type" => "text/plain", "Transfer-Encoding" => "chunked" }, 
          body
      )
    end

    Delay.create(@evloop, 1) do 
      body.call "hello\n" 
    end

    Delay.create(@evloop, 1.5) do 
      body.call "world\n" 
      body.call nil
    end

    [0, nil, nil]
  end
end

evloop = Rev::Loop.default 
app = App.new(evloop)
Flow.start_server(evloop, app)
evloop.run
