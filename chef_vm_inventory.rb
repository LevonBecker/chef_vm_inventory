#!/usr/bin/env ruby

#region Includes

  require 'fileutils'
  require 'json'
  require 'yaml'
  require 'highline/import'
  require 'optparse'
  require 'pp'
  require 'open3'
  require 'chef'
  # require 'media_wiki'

#endregion Includes


#region Options

  # Defaults
  @options = Hash.new
  @options['settings_path'] = File.join(File.dirname(File.expand_path(__FILE__)), 'chef_vm_inventory_settings.json')
  @options['dnsxref_path'] = File.join(File.dirname(File.expand_path(__FILE__)), 'dns_cross_reference.json')

  # Options Parsing
  options_parser = OptionParser.new do |opts|
    opts.banner = "Usage: vm_inventory.rb [options]"
    opts.separator ""
    opts.separator "Options:"

    opts.on("-s", "--settingspath SETTINGSPATH", "JSON or YAML Configuration File Full Path if not in same Directory") do |opt|
      @options['settings_path'] = opt
    end

    opts.on_tail("-h", "--help", "Show this message" ) do
      puts opts
      exit
    end

  end
  options_parser.parse(ARGV)

#endregion Options


#region Variables

  # Import Settings (JSON or YAML)
  if File.exist?(@options['settings_path'])
    file_extension = File.extname(@options['settings_path'])
    if file_extension == '.json'
      @settings = JSON.parse( IO.read(@options['settings_path']) )
    elsif file_extension == '.yaml' || file_extension == '.yml'
      @settings = YAML.load_file(@options['settings_path'])
    else
      puts "ERROR: Unknown File Type (#{file_extension})"
      raise
    end
  else
    puts 'ERROR: Settings File Not Found!'
    exit 1
    raise
  end

  # Import DNS Cross Reference
  if File.exists?(@options['dnsxref_path'])
    @dnsxref = JSON.parse( IO.read(@options['dnsxref_path']) )
  end

  # Versions
  @script_version  = '1.0.3-20140619'

#endregion Variables


#region Prerequisites

  # Check Settings
  if @settings['output_path'].nil?
    puts 'ERROR: Output Path Not Found!'
    raise
  end
  if @settings['output_filename'].nil?
    puts 'ERROR: Output Filename Not Found!'
    raise
  end
  FileUtils::mkdir_p @settings['output_path'] unless Dir.exists?(@settings['output_path'])

#endregion Prerequisites


#region Connect to Chef API

  Chef::Config[:node_name]= @settings['chef_config']['node_name']
  Chef::Config[:client_key]= @settings['chef_config']['client_key']
  Chef::Config[:chef_server_url]= @settings['chef_config']['chef_server_url']
  # Chef::Config.from_file(File.expand_path('~/.chef/knife.rb'))

#endregion Connect to Chef API


#region Methods

  def show_header
    system 'clear' unless system 'cls'
    puts "Chef VM Inventory v#{@script_version} | Ruby v#{RUBY_VERSION} | by Levon Becker"
    puts '------------------------------------------------------------------'
  end

  def show_subheader(subtext)
    puts subtext
    puts '------------------------------------------------------------------'
    puts ''
  end

  def get_environments
    show_header
    show_subheader('FETCHING ALL ENVIRONMENTS')
    puts 'Please Wait...'
    puts ''

    exclude_list = [
        '_default'
    ]

    # Query Chef Server for List of Environments
    # Returns a Chef Environment Object
    get_env = Chef::Environment.list('*')

    # Remove Excluded from List and Convert to Array
    filtered_envs = Array.new
    get_env.keys.each do |env|
      unless exclude_list.include?(env)
        filtered_envs << env
      end
    end

    edited_envs = Array.new
    filtered_envs.each do |env|
      edited_envs << env.gsub(/(uat|dev|qa|stg|stage|prd|prod)$/, '')
    end

    @envs = Array.new
    @envs = edited_envs.uniq
  end

  def get_data
    query = Chef::Search::Query.new

    @results = Hash.new
    @envs.sort.each do |env|
      # Array of Chef::Node Objects Returned (.first drops the first unnecessary array returned)
      nodes = query.search('node', "chef_environment:#{env}*").first rescue []

      # Filter out empty environments
      unless nodes.nil? or nodes.empty?
        @results[env] = Hash.new
        nodes.each do |node|
          nodename = node.name.to_s
          @results[env][nodename] = Hash.new
          @results[env][nodename]['name'] = node.name
          @results[env][nodename]['fqdn'] = 'Unknown'
          @results[env][nodename]['cpu'] = 'Unknown'
          @results[env][nodename]['memory'] = 'Unknown'
          @results[env][nodename]['ip'] = 'Unknown'

          @results[env][nodename]['fqdn'] = node['fqdn'] unless node['fqdn'].nil?
          @results[env][nodename]['cpu'] = node['cpu']['total'] unless node['cpu'].nil?
          @results[env][nodename]['memory'] = node['memory']['total'].to_f / 1048576 unless node['memory'].nil?
          @results[env][nodename]['ip'] = node['ipaddress'] unless node['ipaddress'].nil?
          @results[env][nodename]['role'] = node.run_list.collect {|x| x.to_s.gsub(/.*\[(.*)\]/, '\1') }.to_s.gsub(/["\[\]]/, '')
          @results[env][nodename]['env'] = node.chef_environment
          @results[env][nodename]['platform_family'] = node['platform_family']
          @results[env][nodename]['platform_version'] = node['platform_version']

          # Fetch + Set HD size of /cust
          @results[env][nodename]['hd'] = 'Unknown'
          if !node.nil? and node.has_key?('filesystem') and !node.filesystem.nil?
            node.filesystem.keys.each do |keyname|
              keyname.match(/.dev.mapper.*cust/) do |found_cust|
                @results[env][nodename]['hd'] = node.filesystem[keyname].kb_size.to_f / 1048576 if node.filesystem[keyname].has_key?('kb_size')
              end
            end
          end

          # Ternary Operator x ? y : z (if x then y else z)
          # Set HD and Memory Rounded Off Size
          @results[env][nodename]['memory_ceil'] = @results[env][nodename]['memory'] == 'Unknown' ? 'Unknown' : @results[env][nodename]['memory'].ceil
          @results[env][nodename]['hd_ceil'] = @results[env][nodename]['hd'] == 'Unknown' ? 'Unknown' : @results[env][nodename]['hd'].ceil

          # DNS Cross Reference
          if @dnsxref.has_key?(node['fqdn'])
            @results[env][nodename]['dns'] = @dnsxref[node['fqdn']]
          else
            @results[env][nodename]['dns'] = 'Unknown'
          end
        end
      end
    end
  end

  def format_mediwiki
    @mediawiki = String.new
    @results.sort.each do |env,nodes|
      # Table Header
      header = <<-EOH
=== #{env}* ===

{|class="wikitable sortable" width="100%"
! Node Name !! Server Name !! DNS Alias !! Environment !! Roles !! CPU !! RAM !! H/D !! IP Address !! Platform
EOH
      @mediawiki << header

      nodes.each do |node,items|
        # Output each Nodes Information, Add Caridge Return, Close Row "|-" and Add another Caridge return
        @mediawiki << "|-\n| #{node} || #{items['fqdn']} || #{items['dns']} || #{items['env']} || #{items['role']} || #{items['cpu']} || #{items['memory_ceil']} || #{items['hd_ceil']} || #{items['ip']} || #{items['platform_family']}_#{items['platform_version']}\n" unless items.nil?
      end
      # Close Table "|}"
      @mediawiki << "|}\n"
    end
  end

  def format_csv
    # Table Header
    header = <<-EOH
Root Environment,Server,Name,Node Name,DNS,Alias,Environment,Roles,CPU,RAM,HD,IP,Platform
    EOH

    @csv = String.new
    @csv << header

    @results.each do |root_env,nodes|
      nodes.each do |node,items|
        @csv << "#{root_env},#{items['fqdn']},#{node},#{items['dns']},#{items['env']},#{items['role']},#{items['cpu']},#{items['memory_ceil']},#{items['hd_ceil']},#{items['ip']},#{items['platform_family']}_#{items['platform_version']}\n" unless items.nil?
      end
    end
  end

  # TODO: WIP
  # def output_post_mediawiki
  #   mw = MediaWiki::Gateway.new('https://infracoe.nike.net/wiki/api.php')
  #   mw.login('RubyBot', 'pa$$w0rd')
  #   mw.create('Reference:VM_Inventory', 'Hello world!', :summary => 'My first page')
  # end

  def output_console_mediawiki
    show_header
    show_subheader('OUTPUTING MEDIAWIKI CONSOLE')
    puts 'Please Wait...'
    puts ''
    format_mediwiki
    puts @mediawiki
  end

  def output_file_mediawiki
    show_header
    show_subheader('OUTPUTING MEDIAWIKI FILE')
    puts 'Please Wait...'
    puts ''

    format_mediwiki
    File.open("#{@settings['output_path']}/#{@settings['output_filename']}.txt", 'w') { |file| file.write(@mediawiki) }
  end

  def output_file_csv
    show_header
    show_subheader('OUTPUTING CSV FILE')
    puts 'Please Wait...'
    puts ''

    format_csv
    File.open("#{@settings['output_path']}/#{@settings['output_filename']}.csv", 'w') { |file| file.write(@csv) }
  end

  def output_file_json
    show_header
    show_subheader('OUTPUTING JSON FILE')
    puts 'Please Wait...'
    puts ''

    File.open("#{@settings['output_path']}/#{@settings['output_filename']}.json",'w') do |f|
      f.write(@results.to_json)
    end
  end

  def output_file_yaml
    show_header
    show_subheader('OUTPUTING YAML FILE')
    puts 'Please Wait...'
    puts ''

    File.open("#{@settings['output_path']}/#{@settings['output_filename']}.yml",'w') do |f|
      f.write(@results.to_yaml)
    end
  end

#endregion Methods


#region Menu: Action Selection

  show_header
  show_subheader('SELECT ACTION')

  begin
    choose do |menu|
      menu.prompt  =  '> '
      menu.choice(:All_Environments) { puts 'All Environments Selected'; @action = 'all_env' }
      menu.choice(:Select_Environments) { puts 'Select Environments Selected'; @action = 'selected_env' }
      menu.choice(:Quit, 'Exit program.') { exit }
    end
  end

#endregion Menu: Action Selection


#region Menu: Select Environment

  show_header
  show_subheader('SELECT OUTPUT')

  begin
    choose do |menu|
      menu.prompt  =  '> '
      # menu.choice(:Post_to_MediaWiki) { puts 'Post to MediaWiki Selected'; @output_method = 'post_mediawiki' }
      menu.choice(:Console_MediaWiki) { puts 'Console MediaWiki Selected'; @output_method = 'console_mediawiki' }
      menu.choice(:File_MediaWiki) { puts 'File MediaWiki Selected'; @output_method = 'file_mediwiki' }
      menu.choice(:File_CSV) { puts 'File CSV Selected'; @output_method = 'file_csv' }
      menu.choice(:File_JSON) { puts 'File JSON Selected'; @output_method = 'file_json' }
      menu.choice(:File_YAML) { puts 'File YAML Selected'; @output_method = 'file_yaml' }
      menu.choice(:Quit, 'Exit program.') { exit }
    end
  end

#endregion Menu: Select Environment


#region Run Action

  # Get Data
  show_header
  show_subheader('FETCHING DATA')
  puts 'Please Wait...'
  puts ''
  if @action == 'all_env'
    get_environments
    get_data
    @settings['output_filename'] = 'all_environments'
  elsif @action == 'selected_env'
    @envs = @settings['environments'] #unless @settings['environments'].nil?
    get_data
  else
    puts 'ERROR: Unknown Environment Action'
    exit 1
    raise
  end

  # Output Results
  show_header
  show_subheader('GENERATING OUTPUT')
  puts 'Please Wait...'
  puts ''
  if @output_method == 'post_mediawiki'
    # output_post_mediawiki
  elsif @output_method == 'console_mediawiki'
    output_console_mediawiki
  elsif @output_method == 'file_mediwiki'
    output_file_mediawiki
  elsif @output_method == 'file_csv'
    output_file_csv
  elsif @output_method == 'file_json'
    output_file_json
  elsif @output_method == 'file_yaml'
    output_file_yaml
  else
    puts 'ERROR: Unknown Output Action'
    exit 1
    raise
  end

  unless @output_method == 'console_mediawiki'
    show_header
    show_subheader('COMPLETED')
  end


#endregion Run Action


=begin

  TODO:
  1. Additionally Split based on roles?

=end