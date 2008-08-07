# copyright ryah dahl all rights reserved
#
require 'rubygems'
require 'rev'
require File.dirname(__FILE__) + "/../ext/ebb_request_parser_ffi"

module Flow

  # The only public method
  # the rest is private.
  #
  # grass and breadcrumbs and water flow 
  # in the darkness for you
  def self.start_server(evloop, app, options = {})
    socket = TCPServer.new("localhost", (options[:port] || 4001).to_i)
    server = Flow::Server.new(socket, app)
    server.attach(evloop)
  end

  class Server < Rev::Server
    def initialize(listen_socket, app) 
      super(listen_socket, Flow::Connection, app)
    end
  end

  class Connection < Rev::IO
    TIMEOUT = 3 
    @@buffer = nil

    def initialize(socket, app)
      @app = app
      @timeout = Timeout.new(self, TIMEOUT) 
      @parser = Ebb::RequestParser.new(self)
      @responses = []
      super(socket)
    end

    def on_connect
    end

    def attach(evloop)
      @timeout.attach(evloop)
      super(evloop)
    end

    def on_close
      @timeout.detach if @timeout.attached?
    end

    def on_timeout
      close
    end

    def on_request(request)
      request.connection = self
      fiber = Fiber.new { process(request) }
      if fiber.resume == :wait_for_read
        request.fiber = fiber
      end
    end

    # This is a template async response. N.B. Can't use string for body on 1.9
    AsyncStatus = 0
    AsyncResponse = [AsyncStatus, {}, []].freeze
    
    def process(req)
      # Setup our response processing callback for async status and headers.
      req.env['async.callback'] = proc { |response| queue_response(req, response) }
      
      # for non-async capable frameworks, where we can't give back and async
      # response.
      response = AsyncResponse
      catch(:async) do
        # Use a single variable, in case we get a Rack::Response object...
        response = @app.call(req.env)
      end
      
      # queue the response unless we're going async...
      queue_response(req, response) unless response.to_a.first == AsyncStatus
    end
    
    def queue_response(req, response)
      req.res.call(*response.to_a)
      @responses << req.res
      write_response
    end

    def write_response
      return unless res = @responses.first
      
      res.output.each do |chunk|
        write(chunk)
      end
    end

    def on_write_complete
      return unless res = @responses.first
      if res.finished
        @responses.shift
        if res.last 
          close 
          return
        end
      end 
      write_response
    end

    def on_read(data)
      @parser.execute(data)
    rescue Ebb::RequestParser::Error
      close
    end

    class Timeout < Rev::TimerWatcher
      def initialize(connection, timeout)
        @connection = connection
        super(timeout, false)
      end

      def on_timer
        detach
        @connection.__send__(:on_timeout)
      end
    end
  end

  class Response
    attr_reader :output, :finished
    attr_accessor :last
    def initialize(connection, last)
      @connection = connection
      @last = last
      @output = []
      @finished = false
      @chunked = false 
    end

    def call(status, headers, body)
      @output << "HTTP/1.1 #{status} #{HTTP_STATUS_CODES[status.to_i]}\r\n"
      headers.each { |field, value| @output << "#{field}: #{value}\r\n" }
      @output << "\r\n"

      # XXX i would prefer to do
      # @chunked = true unless body.respond_to?(:length)
      @chunked = true if headers["Transfer-Encoding"] == "chunked"
      # I also don't like this
      @last = true if headers["Connection"] == "close"

      # Note: not setting Content-Length. do it yourself.
      
      ## XXX Have to do this so it is known when end is recieved!
      if body.respond_to?(:callback)
        body.callback do
          @finished = true
          @output << "0\r\n\r\n"
        end
      end
      if body.respond_to?(:errback)
        body.errback do
          # TODO / XXX - probably want to close connection here...
          @finished = true
          @output << "0\r\n\r\n"
        end
      end
      
      body.each do |chunk|
        @output << encode(chunk)
        @connection.write_response
      end
    end
    
    def encode(chunk)
      @chunked ? "#{chunk.length.to_s(16)}\r\n#{chunk}\r\n" : chunk
    end

    HTTP_STATUS_CODES = {
      100  => 'Continue', 
      101  => 'Switching Protocols', 
      200  => 'OK', 
      201  => 'Created', 
      202  => 'Accepted', 
      203  => 'Non-Authoritative Information', 
      204  => 'No Content', 
      205  => 'Reset Content', 
      206  => 'Partial Content', 
      300  => 'Multiple Choices', 
      301  => 'Moved Permanently', 
      302  => 'Moved Temporarily', 
      303  => 'See Other', 
      304  => 'Not Modified', 
      305  => 'Use Proxy', 
      400  => 'Bad Request', 
      401  => 'Unauthorized', 
      402  => 'Payment Required', 
      403  => 'Forbidden', 
      404  => 'Not Found', 
      405  => 'Method Not Allowed', 
      406  => 'Not Acceptable', 
      407  => 'Proxy Authentication Required', 
      408  => 'Request Time-out', 
      409  => 'Conflict', 
      410  => 'Gone', 
      411  => 'Length Required', 
      412  => 'Precondition Failed', 
      413  => 'Request Entity Too Large', 
      414  => 'Request-URI Too Large', 
      415  => 'Unsupported Media Type', 
      500  => 'Internal Server Error', 
      501  => 'Not Implemented', 
      502  => 'Bad Gateway', 
      503  => 'Service Unavailable', 
      504  => 'Gateway Time-out', 
      505  => 'HTTP Version not supported'
    }.freeze
  end
end

module Ebb
  class RequestParser
    class Request 
      BASE_ENV = {
        'SERVER_NAME' => '0.0.0.0',
        'SCRIPT_NAME' => '',
        'QUERY_STRING' => '',
        'SERVER_SOFTWARE' => "Flow 0.0.0",
        'SERVER_PROTOCOL' => 'HTTP/1.1',
        'rack.version' => [0, 1],
        'rack.errors' => STDERR,
        'rack.url_scheme' => 'http',
        'rack.multiprocess' => false,
        'rack.run_once' => false
      }
      attr_accessor :fiber, :connection

      def env
        @env ||= begin
          env = @env_ffi.update(BASE_ENV)
          env["rack.input"] = self
          env["CONTENT_LENGTH"] = env["HTTP_CONTENT_LENGTH"]
          env["async.callback"] = response
          env
        end
      end

      def response
        @response ||= begin
          last = !keep_alive? # this is the last response if the request isnt keep-alive
          Flow::Response.new(@connection, last)
        end
      end

      def input
        @input ||= Rev::Buffer.new
      end


      def read(len = nil)
        if input.size == 0
          if @body_complete
            @fiber = nil
            nil
          else
            Fiber.yield(:wait_for_read)
            ""
          end
        else
          input.read(len)
        end
      end

      # XXX hacky...

      def on_body(chunk)
        input.append(chunk)
        if @fiber
          @fiber = nil if @fiber.resume != :wait_for_read
        end
      end

      def on_complete
        if @fiber
          @fiber = nil if @fiber.resume != :wait_for_read
        end
      end
    end
  end
end
