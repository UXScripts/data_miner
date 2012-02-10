require 'posix/spawn'
require 'uri'
class DataMiner
  # Note that you probably shouldn't put taps into your Gemfile, because it depends on sequel and other gems that may not compile on Heroku (etc.)
  #
  # This class automatically detects if you have Bundler installed, and if so, executes the `taps` binary with a "clean" environment (i.e. one that will not pay attention to the fact that taps is not in your Gemfile)
  class Tap
    attr_reader :config
    attr_reader :description
    attr_reader :source
    attr_reader :options

    def initialize(config, description, source, options = {})
      @config = config
      @options = options.dup
      @options.stringify_keys!
      @description = description
      @source = source
    end
    
    def resource
      config.resource
    end
    
    def inspect
      %{#<DataMiner::Tap(#{resource}): #{description} (#{source})>}
    end
    
    def run
      [ source_table_name, resource.table_name ].each do |possible_obstacle|
        if connection.table_exists? possible_obstacle
          connection.drop_table possible_obstacle
        end
      end
      taps_pull
      if needs_table_rename?
        connection.rename_table source_table_name, resource.table_name
      end
      nil
    end
    
    # sabshere 1/25/11 what if there were multiple connections
    # blockenspiel doesn't like to delegate this to #resource
    def connection
      ::ActiveRecord::Base.connection
    end
    
    def db_config
      @db_config ||= connection.instance_variable_get(:@config).stringify_keys.merge(options.except('source_table_name'))
    end
    
    def source_table_name
      options['source_table_name'] || resource.table_name
    end
    
    def needs_table_rename?
      source_table_name != resource.table_name
    end
    
    def adapter
      case connection.adapter_name
      when /mysql2/i
        'mysql2'
      when /mysql/i
        'mysql'
      when /postgres/i
        'postgres'
      when /sqlite/i
        'sqlite'
      end
    end

    # never optional
    def database
      db_config['database']
    end
    
    DEFAULT_PORTS = {
      'mysql' => 3306,
      'mysql2' => 3306,
      'postgres' => 5432
    }
    
    DEFAULT_USERNAMES = {
      'mysql' => 'root',
      'mysql2' => 'root',
      'postgres' => ''
    }
    
    DEFAULT_PASSWORDS = {}
    DEFAULT_PASSWORDS.default = ''
    
    DEFAULT_HOSTS = {}
    DEFAULT_HOSTS.default = 'localhost'

    %w{ username password port host }.each do |x|
      module_eval %{
        def #{x}
          db_config['#{x}'] || DEFAULT_#{x.upcase}S[adapter]
        end
      }
    end
    
    # "user:pass"
    # "user"
    # nil
    def userinfo
      if username.present?
        [username, password].select(&:present?).join(':')
      end
    end
    
    def db_url
      case adapter
      when 'sqlite'
        "sqlite:://#{database}"
      else
        ::URI::Generic.new(adapter, userinfo, host, port, nil, "/#{database}", nil, nil, nil).to_s
      end
    end
    
    def taps_pull
      args = [
        'taps',
        'pull',
        db_url,
        source,
        '--indexes-first',
        '--tables',
        source_table_name
      ]
      child = nil
      
      # https://github.com/carlhuda/bundler/issues/1579
      if defined?(::Bundler)
        ::Bundler.with_clean_env do
          child = ::POSIX::Spawn::Child.new(*args)
        end
      else
        child = ::POSIX::Spawn::Child.new(*args)
      end
      
      unless child.success?
        raise %{[data_miner gem] Got "#{child.err}" when tried "#{args.join(' ')}". You need to have the taps binary in your PATH. Putting it in your Gemfile, however, is not recommended.}
      end
    end
  end
end
