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
  #
  #
  # dear reader, your rack application should have a method
  # :call. This method should return a triple:
  #   [status, headers, body]
  # Flow prefers that you use body.shift to return chunks of 
  # the response. 
  #
  # Feel free to 
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

      @requests = []
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

    def process(req)
      @requests << req
      res = req.response
      status, headers, body = @app.call(req.env)

      # James Tucker's async response scheme
      # check out
      # http://github.com/raggi/thin/tree/async_for_rack/example/async_app.ru
      res.call(status, headers, body) if status != 0 

      @responses << res
      write_response
    end

    def write_response
      return unless res = @responses.first
      if res.finished?
        @responses.shift
        if res.last
          close
        else
          write_response
        end
      else 
        while chunk = res.output.shift
          write(chunk)
        end
      end
    end

    def on_write_complete
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

    def finished?
      @finished 
    end

    def call(status, headers, body)
      head = "HTTP/1.1 #{status} #{HTTP_STATUS_CODES[status.to_i]}\r\n"
      headers.each { |field, value| head << "#{field}: #{value}\r\n" }
      head << "\r\n"
      @output << head

      # XXX i would prefer to do
      # @chunked = true unless body.respond_to?(:length)
      @chunked = true if headers["Content-Encoding"] == "chunked"

      body.each do |chunk|
        @output << encode(chunk)
        @finished = true if chunk.nil?
        @connection.write_response
      end
    end
    
    def encode(chunk)
      c = chunk || "" # encodes a nil chunk too
      @chunked ?  "#{c.length.to_s(16)}\r\n#{c}\r\n" : c
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
          last = !keep_alive?
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
