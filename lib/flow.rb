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
      fiber = Fiber.new { process(request) }
      if fiber.resume == :wait_for_read
        request.fiber = fiber
      end
    end

    def process(req)
      @requests << req
      # p req.env
      status, headers, body = @app.call(req.env)
      res = Response.new(status, headers, body)
      res.last = !req.keep_alive?

      # FIXME
      unless body.respond_to?(:shift)
        if body.kind_of?(String)
          body = [body]
        else
          b = []
          body.each { |chunk| b << chunk }
          body = b
        end
      end

      @responses << res
      start_writing if @responses.length == 1 
    end

    def start_writing
      write(@responses.first.chunk) 
    end

    def on_write_complete
      if res = @responses.first
        if chunk = res.shift
          write(chunk)
        else
          if res.last
            close 
          else
            @responses.shift
            on_write_complete
          end
        end
      end
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
    attr_reader :chunk
    attr_accessor :last
    def initialize(status, headers, body)
      @body = body
      @chunk = "HTTP/1.1 #{status} #{HTTP_STATUS_CODES[status.to_i]}\r\n"
      headers.each { |field, value| @chunk << "#{field}: #{value}\r\n" }
      @chunk << "\r\n#{@body.shift}" 
      @last = false
    end

    # if returns nil, there is nothing else to write
    # otherwise returns then next chunk needed to write.
    # on writable call connection.write(response.shift) 
    def shift
      @chunk = @body.shift
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
      attr_accessor :fiber

      def env
        @env ||= begin
          env = @env_ffi.update(BASE_ENV)
          env["rack.input"] = self
          env["CONTENT_LENGTH"] = env["HTTP_CONTENT_LENGTH"]
          env
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
