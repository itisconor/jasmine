require 'socket'
require 'erb'
require 'json'

module Jasmine
  # this seemingly-over-complex method is necessary to get an open port on at least some of our Macs
  def self.open_socket_on_unused_port
    infos = Socket::getaddrinfo("localhost", nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM, 0, Socket::AI_PASSIVE)
    families = Hash[*infos.collect { |af, *_| af }.uniq.zip([]).flatten]

    return TCPServer.open('0.0.0.0', 0) if families.has_key?('AF_INET')
    return TCPServer.open('::', 0) if families.has_key?('AF_INET6')
    return TCPServer.open(0)
  end

  def self.find_unused_port
    socket = open_socket_on_unused_port
    port = socket.addr[1]
    socket.close
    port
  end

  def self.server_is_listening_on(hostname, port)
    require 'socket'
    begin
      socket = TCPSocket.open(hostname, port)
    rescue Errno::ECONNREFUSED
      return false
    end
    socket.close
    true
  end

  def self.wait_for_listener(port, name = "required process", seconds_to_wait = 10)
    time_out_at = Time.now + seconds_to_wait
    until server_is_listening_on "localhost", port
      sleep 0.1
      puts "Waiting for #{name} on #{port}..."
      raise "#{name} didn't show up on port #{port} after #{seconds_to_wait} seconds." if Time.now > time_out_at
    end
  end

  def self.kill_process_group(process_group_id, signal="TERM")
    Process.kill signal, -process_group_id # negative pid means kill process group. (see man 2 kill)
  end

  class RunAdapter
    def initialize(spec_files_or_proc)
      @spec_files_or_proc = spec_files_or_proc
    end

    def call(env)
      spec_files = @spec_files_or_proc
      spec_files = spec_files.call if spec_files.respond_to?(:call)

      body = ERB.new(File.read(File.join(File.dirname(__FILE__), "run.html"))).result(binding)
      [
        200,
        { 'Content-Type' => 'text/html' },
        body
      ]
    end
  end

  class Redirect
    def initialize(url)
      @url = url
    end

    def call(env)
      [
        302,
        { 'Location' => @url },
        []
      ]
    end
  end

  class SimpleServer
    def self.start(port, spec_files_or_proc, mappings)
      require 'thin'

      config = {
        '/' => Jasmine::Redirect.new('/run.html'),
        '/run.html' => Jasmine::RunAdapter.new(spec_files_or_proc)
      }
      mappings.each do |from, to|
        config[from] = Rack::File.new(to)
      end

      app = Rack::URLMap.new(config)

      Thin::Server.start('0.0.0.0', port, app)
    end
  end

  class SimpleClient
    def initialize(selenium_host, selenium_port, selenium_browser_start_command, http_address)
      require 'selenium'
      @driver = Selenium::Client::Driver.new(
        selenium_host,
        selenium_port,
        selenium_browser_start_command,
        http_address
      )
      @http_address = http_address
    end

    def tests_have_finished?
      @driver.get_eval("window.jasmine.getEnv().currentRunner.finished") == "true"
    end

    def connect
      @driver.start
      @driver.open("/run.html")
    end

    def disconnect
      @driver.stop
    end

    def run
      until tests_have_finished? do
        sleep 0.1
      end

      puts @driver.get_eval("window.getResults()")
      failed_count = @driver.get_eval("window.jasmine.getEnv().currentRunner.getResults().failedCount").to_i
      failed_count == 0
    end

    def eval_js(script)
      escaped_script = "'" + script.gsub(/(['\\])/) { '\\' + $1 } + "'"

      result = @driver.get_eval("eval(#{escaped_script}, window)")
      JSON.parse("[#{result}]")[0]
    end
  end

  class Runner
    def initialize(selenium_jar_path, spec_files, dir_mappings)
      @selenium_jar_path = selenium_jar_path
      @spec_files = spec_files
      @dir_mappings = dir_mappings

      @selenium_pid = nil
      @jasmine_server_pid = nil
    end

    def start
      start_servers
      @client = Jasmine::SimpleClient.new("localhost", @selenium_server_port, "*firefox", "http://localhost:#{@jasmine_server_port}/")
      @client.connect
    end

    def stop
      @client.disconnect
      stop_servers
    end

    def start_servers
      @jasmine_server_port = Jasmine::find_unused_port
      @selenium_server_port = Jasmine::find_unused_port

      @selenium_pid = fork do
        Process.setpgrp
        exec "java -jar #{@selenium_jar_path} -port #{@selenium_server_port} > /dev/null 2>&1"
      end
      puts "selenium started.  pid is #{@selenium_pid}"

      @jasmine_server_pid = fork do
        Process.setpgrp
        Jasmine::SimpleServer.start(@jasmine_server_port, @spec_files, @dir_mappings)
        exit! 0
      end
      puts "jasmine server started.  pid is #{@jasmine_server_pid}"

      Jasmine::wait_for_listener(@selenium_server_port, "selenium server")
      Jasmine::wait_for_listener(@jasmine_server_port, "jasmine server")
    end

    def stop_servers
      puts "shutting down the servers..."
      Jasmine::kill_process_group(@selenium_pid) if @selenium_pid
      Jasmine::kill_process_group(@jasmine_server_pid) if @jasmine_server_pid
    end

    def run
      begin
        start
        puts "servers are listening on their ports -- running the test script..."
        tests_passed = @client.run
      ensure
        stop
      end
      return tests_passed
    end

    def eval_js(script)
      @client.eval_js(script)
    end
  end
end
