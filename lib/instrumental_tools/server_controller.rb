require 'instrumental_tools/metric_script_executor'
require 'instrumental_tools/system_inspector'
require 'pidly'
require 'yaml'

class ServerController < Pidly::Control
  COMMANDS = [:start, :stop, :status, :restart, :clean, :kill, :foreground]

  attr_accessor :run_options, :pid
  attr_reader :current_api_key

  before_start do
    extra_info = if run_options[:daemon]
                   "(#{run_options[:pid_location]}), log: #{run_options[:log_location]}"
                 end
    puts "Starting daemon process: #{@pid} #{extra_info}"
  end

  start :foreground

  stop do
    puts "Attempting to kill daemon process: #{@pid}"
  end

  error do
    puts 'Error encountered'
  end

  def initialize(options={})
    @run_options = options.delete(:run_options) || {}
    super(options)
  end

  def foreground
    run
  end

  def collector_address
    [run_options[:collector], run_options[:port]].compact.join(':')
  end

  def user_specified_api_key
    run_options[:api_key]
  end

  def config_file_api_key
    if config_file_available?
      config_contents = YAML.load(File.read(run_options[:config_file]))
      if config_contents.is_a?(Hash)
        config_contents['api_key']
      end
    end
  rescue Exception => e
    puts "Error loading config file %s: %s" % [run_options[:config_file], e.message]
    nil
  end

  def configured_api_key
    (user_specified_api_key || config_file_api_key).to_s.strip
  end

  def build_agent(key, address, enabled)
    secure_protocol = address.split(':').last != '8000'
    Instrumental::Agent.new(key, collector: address, enabled: enabled, secure: secure_protocol)
  end

  def set_new_agent(key, address)
    key              = key.to_s.strip
    @current_api_key = key
    @agent           = build_agent(key, collector_address, key.size > 0)
  end

  def agent
    if key_has_changed?
      set_new_agent(configured_api_key, collector_address)
    end
    @agent
  end

  def report_interval
    run_options[:report_interval]
  end

  def hostname
    run_options[:hostname]
  end

  def script_location
    run_options[:script_location]
  end

  def script_executor
    @executor ||= MetricScriptExecutor.new(script_location)
  end

  def next_run_at(at_moment = Time.now.to_i)
    (at_moment - at_moment % report_interval) + report_interval
  end

  def time_to_sleep
    t = Time.now.to_i
    [next_run_at(t) - t, 0].max
  end

  def config_file_available?
    File.exists?(run_options[:config_file])
  end

  def enabled?
    agent.enabled
  end

  def debug?
    !!run_options[:debug]
  end

  def enable_scripts?
    !!run_options[:enable_scripts]
  end

  def key_has_changed?
    current_api_key != configured_api_key
  end

  def run
    puts "instrument_server version #{Instrumental::Tools::VERSION} started at #{Time.now.utc}"
    puts "Collecting stats under the hostname: #{hostname}"
    loop do
      sleep time_to_sleep
      if enabled?
        inspector = SystemInspector.new
        inspector.load_all
        count = 0
        inspector.gauges.each do |stat, value|
          metric = [hostname, stat].join(".")
          agent.gauge(metric, value)
          if debug?
            puts [metric, value].join(":")
          end
          count += 1
        end
        if enable_scripts?
          script_executor.run.each do |(stat, value, time)|
            metric = [hostname, stat].join(".")
            agent.gauge(metric, value, time)
            if debug?
              puts [metric, value].join(":")
            end
            count += 1
          end
        end
        agent.flush
        agent.stop
        if debug?
          puts "Sent #{count} metrics"
        end
      end
    end
  end

  alias_method :clean, :clean!
end
