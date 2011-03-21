require 'socket'
require 'tempfile'
require 'timeout'

#require File.expand_path(File.dirname(__FILE__) + '/capturer')
require File.expand_path(File.dirname(__FILE__) + '/exception')
require File.expand_path(File.dirname(__FILE__) + '/global')
require File.expand_path(File.dirname(__FILE__) + '/helpers')
require File.expand_path(File.dirname(__FILE__) + '/message')
require File.expand_path(File.dirname(__FILE__) + '/response')

module RTSP

  # Allows for pulling streams from an RTSP server.
  class Client
    include RTSP::Helpers
    extend RTSP::Global

    DEFAULT_TIMEOUT = 30
    MAX_BYTES_TO_RECEIVE = 3000

    attr_reader :server_uri
    attr_reader :cseq
    attr_reader :session
    attr_reader :supported_methods
    attr_accessor :tracks

    # TODO: Break Stream out in to its own class.
    # See RFC section A.1.
    attr_reader :session_state

    # Use to configure options for all clients.  See RTSP::Global for the options.
    def self.configure
      yield self if block_given?
    end

    # @param [String] rtsp_url URL to the resource to stream.  If no scheme is
    # given, "rtsp" is assumed.  If no port is given, 554 is assumed.
    def initialize(rtsp_url, args={})
      @server_uri = build_resource_uri_from rtsp_url
      @args = args

      @cseq = 1
      @session_state = :init
      @session = 0
      @timeout = args[:timeout] || DEFAULT_TIMEOUT
      @socket = @args[:socket] || TCPSocket.new(@server_uri.host, @server_uri.port)
      @args[:logger] = RTSP::Client.log? ? RTSP::Client.logger : nil
    end

    # The URL for the RTSP server to talk to can change if multiple servers are
    # involved in delivering content.  This method can be used to change the
    # server to talk to on the fly.
    #
    # @param [String] new_url The new server URL to use to communicate over.
    def server_url=(new_url)
      @server_uri = build_resource_uri_from new_url
    end

    # Sends the message over the socket.
    #
    # @param [RTSP::Message] message
    # @return [RTSP::Response]
    def send_message message
      RTSP::Client.log "Sending #{message.method_type.upcase} to #{message.request_uri}"
      message.to_s.each_line { |line| RTSP::Client.log line.strip }

      begin
        response = Timeout::timeout(@timeout) do
          @socket.send(message.to_s, 0)
          socket_data = @socket.recvfrom MAX_BYTES_TO_RECEIVE
          RTSP::Response.new socket_data.first
        end
      rescue Timeout::Error
        raise RTSP::Exception, "Request took more than #{@timeout} seconds to send."
      end

      RTSP::Client.log "Received response:"

      if response
        response.to_s.each_line { |line| RTSP::Client.log line.strip }
      end

      response
    end

    # Sends an OPTIONS message to the server specified by @server_uri.  Sets
    # @supported_methods based on the list of supported methods returned in the
    # Public headers.
    #
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def options(additional_headers={})
      message = RTSP::Message.options(@server_uri.to_s).with_headers({
        cseq: @cseq })
      message.add_headers additional_headers

      request(message) do |response|
        @supported_methods = extract_supported_methods_from response.public
      end
    end

    # TODO: get tracks, IP's, ports, multicast/unicast
    # Sends the DESCRIBE request, then extracts the SDP description into
    # @session_description, extracts the session @start_time and @stop_time,
    # @content_base, media_control_tracks, and aggregate_control_track.
    #
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def describe additional_headers={}
      message = RTSP::Message.describe(@server_uri.to_s).with_headers({
        cseq: @cseq })
      additional_headers.each_pair { |h| message.header h.key, h.value }

      request(message) do |response|
        @session_description =  response.body
        #@session_start_time =   response.body.start_time
        #@session_stop_time =    response.body.stop_time
        @content_base = build_resource_uri_from response.content_base

        @media_control_tracks =     media_control_tracks
        @aggregate_control_track =  aggregate_control_track
      end
    end

    # @param [String] request_url The URL to post the presentation or media
    # object to.
    # @param [SDP::Description] description The SDP description to send to the
    # server.
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def announce(request_url, description, additional_headers={})
      message = RTSP::Message.announce(request_url).with_headers({ cseq: @cseq })
      additional_headers.each_pair { |h| message.header h.key, h.value }
      message.body = description.to_s

      request(message)
    end

    # TODO: parse Transport header (http://tools.ietf.org/html/rfc2326#section-12.39)
    # TODO: @session numbers are relevant to tracks, and a client can play multiple tracks at the same time.
    # Sends the SETUP request, then sets @session to the value returned in the
    # Session header from the server, then sets the @session_state to :ready.
    #
    # @param [String] track
    # @param [Hash] additional_headers
    # @return [RTSP::Response] The response formatted as a Hash.
    def setup(track, additional_headers={})
      message = RTSP::Message.setup(track).with_headers({ cseq: @cseq })
      additional_headers.each_pair { |h| message.header h.key, h.value }

      request(message) do |response|
        if @session_state == :init
          @session_state = :ready
        end

        @session = response.session
        @transport = parse_transport_from response.transport
      end
    end

    def parse_transport_from field_string
      fields = field_string.split ";"
      transport = {}
      specifier = fields.shift
      transport[:protocol] = specifier.split("/")[0]
      transport[:profile] =  specifier.split("/")[1]
      #@transport[:lower_transport] = specifier.split("/")[2].downcase.to_sym || :udp
      transport[:network_type] = fields.shift.to_sym || :multicast

      extras = fields.inject({}) do |result, field_and_value_string|
        field_and_value_array = field_and_value_string.split "="
        result[field_and_value_array.first.to_sym] = field_and_value_array.last
        result
      end
      transport.merge! extras
    end

    # Sends the PLAY request and sets @session_state to :playing.
    #
    # @param [String] track
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def play(track, additional_headers={})
      message = RTSP::Message.play(track).with_headers({
          cseq: @cseq, session: @session })
      additional_headers.each_pair { |h| message.header h.key, h.value }

      request(message) { @session_state = :playing }
    end

    # Sends the PAUSE request and sets @session_state to :ready.
    #
    # @param [String] track A track or presentation URL to pause.
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def pause(track, additional_headers={})
      message = RTSP::Message.pause(track).with_headers({
          cseq: @cseq, session: @session })
      additional_headers.each_pair { |h| message.header h.key, h.value }

      request(message) do
        if [:playing, :recording].include? @session_state
          @session_state = :ready
        end
      end
    end

    # Sends the TEARDOWN request, then resets all state-related instance
    # variables.
    #
    # @param [String] track The presentation or media track to teardown.
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def teardown(track, additional_headers={})
      message = RTSP::Message.teardown(track).with_headers({
          cseq: @cseq, session: @session })
      additional_headers.each_pair { |h| message.header h.key, h.value }

      request(message) do
        @session_state = :init
        @session = 0
      end
    end

    # Sends the GET_PARAMETERS request.
    #
    # @param [String] track The presentation or media track to ping.
    # @param [String] body The string containing the parameters to send.
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def get_parameter(track, body="", additional_headers={})
      message = RTSP::Message.get_parameter(track).with_headers({
          cseq: @cseq })
      additional_headers.each_pair { |h| message.header h.key, h.value }
      message.body = body

      request(message)
    end

    # Sends the SET_PARAMETERS request.
    #
    # @param [String] track The presentation or media track to teardown.
    # @param [String] parameters The string containing the parameters to send.
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def set_parameter(track, parameters, additional_headers={})
      message = RTSP::Message.set_parameter(track).with_headers({
          cseq: @cseq })
      additional_headers.each_pair { |h| message.header h.key, h.value }
      message.body = parameters

      request(message)
    end

    # Sends the RECORD request and sets @session_state to :recording.
    #
    # @param [String] track
    # @param [Hash] additional_headers
    # @return [RTSP::Response]
    def record(track, additional_headers={})
      message = RTSP::Message.record(track).with_headers({
          cseq: @cseq, session: @session })
      additional_headers.each_pair { |h| message.header h.key, h.value }

      request(message) { @session_state = :recording }
    end

    # TODO: #ensure_session_and should occur just after receiving the response, not before sending a request.
    # Executes the Request with the arguments passed in, yields the response to
    # the calling block, checks the cseq response and the session response,
    # then increments @cseq by 1.  Handles any exceptions raised during the
    # Request.
    #
    # @param [Hash] new_args
    # @yield [RTSP::Response]
    # @return [RTSP::Response]
    def request message
      begin
        response = send_message message

        compare_sequence_number response.cseq

        if response.code.to_s =~ /2../
          yield response if block_given?
        elsif response.code.to_s =~ /(4|5)../
          if (defined? response.connection) && response.connection == 'Closed'
            reset_state
          end

          raise RTSP::Exception, "#{response.code}: #{response.message}"
        else
          raise RTSP::Exception, "Unknown Response code: #{response.code}"
        end

        @cseq += 1
      rescue RTSP::Exception => ex
        RTSP::Client.log "Got exception: #{ex.message}"
        ex.backtrace.each { |b| RTSP::Client.log b }
      end

      response
    end
=begin
    def connect
      timeout(@timeout) { @socket = TCPSocket.new(@host, @port) } #rescue @socket = nil
    end

    def connected?
      @socket == nil ? true : false
    end

    def disconnect
      timeout(@timeout) { @socket.close } rescue @socket = nil
    end
=end

    # Ensures that @session is set before continuing on.
    #
    # @raise [RTSP::Exception] Raises if @session isn't set.
    # @return Returns whatever the block returns.
    def ensure_session_and
      return_value = ""

      if @session > 0
        return_value = yield if block_given?
      else
        raise RTSP::Exception, "Session number not retrieved from server yet.  Run SETUP first."
      end

      return_value
    end

    # Extracts the URL associated with the "control" attribute from the main
    # section of the session description.
    #
    # @return [String]
    def aggregate_control_track
      aggregate_control = @session_description.attributes.find_all do |a|
        a[:attribute] == "control"
      end

      "#{@content_base}#{aggregate_control.first[:value].gsub(/\*/, "")}"
    end

    # Extracts the value of the "control" attribute from all media sections of
    # the session description (SDP).  You have to call the #describe method in
    # order to get the session description info.
    #
    # @return [Array<String>] The tracks made up of the content base + control
    # track value.
    def media_control_tracks
      tracks = []
      @session_description.media_sections.each do |media_section|
        media_section[:attributes].each do |a|
          tracks << "#{@content_base}#{a[:value]}" if a[:attribute] == "control"
        end
      end

      tracks
    end

    # Compares the sequence number passed in to the current client sequence
    # number (@cseq) and raises if they're not equal.  If that's the case, the
    # server responded to a different request.
    #
    # @param [Fixnum] server_cseq Sequence number returned by the server.
    # @raise [RTSP::Exception]
    def compare_sequence_number server_cseq
      if @cseq != server_cseq
        message = "Sequence number mismatch.  Client: #{@cseq}, Server: #{server_cseq}"
        raise RTSP::Exception, message
      end
    end

    # Compares the session number passed in to the current client session
    # number (@session) and raises if they're not equal.  If that's the case, the
    # server responded to a different request.
    #
    # @param [Fixnum] server_session Session number returned by the server.
    # @raise [RTSP::Exception]
    def compare_session_number server_session
      if @session != server_session
        message = "Session number mismatch.  Client: #{@session}, Server: #{server_session}"
        raise RTSP::Exception, message
      end
    end

    # Takes the methods returned from the Public header from an OPTIONS response
    # and puts them to an Array.
    #
    # @param [String] method_list The string returned from the server containing
    # the list of methods it supports.
    # @return [Array<Symbol>] The list of methods as symbols.
    def extract_supported_methods_from method_list
      method_list.downcase.split(', ').map { |m| m.to_sym }
    end
  end
end