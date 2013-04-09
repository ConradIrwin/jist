require 'net/https'
require 'cgi'
require 'json'
require 'uri'

# It just gists.
module Jist
  extend self

  VERSION = '1.4.0'

  # A list of clipboard commands with copy and paste support.
  CLIPBOARD_COMMANDS = {
    'xclip'   => 'xclip -o',
    'xsel'    => 'xsel -o',
    'pbcopy'  => 'pbpaste',
    'putclip' => 'getclip'
  }

  GITHUB_API_URL   = URI("https://api.github.com/")
  GIT_IO_URL       = URI("http://git.io")

  GITHUB_BASE_PATH = ""
  GHE_BASE_PATH    = "/api/v3"

  # Exception tag for errors raised while gisting.
  module Error;
    def self.exception(*args)
      RuntimeError.new(*args).extend(self)
    end
  end
  class ClipboardError < RuntimeError; include Error end

  # Upload a gist to https://gist.github.com
  #
  # @param [String] content  the code you'd like to gist
  # @param [Hash] options  more detailed options, see
  #   the documentation for {multi_gist}
  #
  # @see http://developer.github.com/v3/gists/
  def gist(content, options = {})
    filename = options[:filename] || "a.rb"
    multi_gist({filename => content}, options)
  end

  # Upload a gist to https://gist.github.com
  #
  # @param [Hash] files  the code you'd like to gist: filename => content
  # @param [Hash] options  more detailed options
  #
  # @option options [String] :description  the description
  # @option options [Boolean] :public  (false) is this gist public
  # @option options [Boolean] :anonymous  (false) is this gist anonymous
  # @option options [String] :access_token  (`File.read("~/.jist")`) The OAuth2 access token.
  # @option options [String] :update  the URL or id of a gist to update
  # @option options [Boolean] :copy  (false) Copy resulting URL to clipboard, if successful.
  # @option options [Boolean] :open  (false) Open the resulting URL in a browser.
  # @option options [Symbol] :output (:all) The type of return value you'd like:
  #   :html_url gives a String containing the url to the gist in a browser
  #   :short_url gives a String contianing a  git.io url that redirects to html_url
  #   :javascript gives a String containing a script tag suitable for embedding the gist
  #   :all gives a Hash containing the parsed json response from the server
  #
  # @return [String, Hash]  the return value as configured by options[:output]
  # @raise [Jist::Error]  if something went wrong
  #
  # @see http://developer.github.com/v3/gists/
  def multi_gist(files, options={})
    json = {}

    json[:description] = options[:description] if options[:description]
    json[:public] = !!options[:public]
    json[:files] = {}

    files.each_pair do |(name, content)|
      raise "Cannot gist empty files" if content.to_s.strip == ""
      json[:files][File.basename(name)] = {:content => content}
    end

    existing_gist = options[:update].to_s.split("/").last
    if options[:anonymous]
      access_token = nil
    else
      access_token = (options[:access_token] || File.read(auth_token_file) rescue nil)
    end

    url = "#{base_path}/gists"
    url << "/" << CGI.escape(existing_gist) if existing_gist.to_s != ''
    url << "?access_token=" << CGI.escape(access_token) if access_token.to_s != ''

    request = Net::HTTP::Post.new(url)
    request.body = JSON.dump(json)
    request.content_type = 'application/json'

    retried = false

    begin
      response = http(api_url, request)
      if Net::HTTPSuccess === response
        on_success(response.body, options)
      else
        raise "Got #{response.class} from gist: #{response.body}"
      end
    rescue => e
      raise if retried
      retried = true
      retry
    end

  rescue => e
    raise e.extend Error
  end

  # Convert long github urls into short git.io ones
  #
  # @param [String] url
  # @return [String] shortened url, or long url if shortening fails
  def shorten(url)
    request = Net::HTTP::Post.new("/")
    request.set_form_data(:url => url)
    response = http(GIT_IO_URL, request)
    case response.code
    when "201"
      response['Location']
    else
      url
    end
  end

  # Log the user into jist.
  #
  # This method asks the user for a username and password, and tries to obtain
  # and OAuth2 access token, which is then stored in ~/.jist
  #
  # @raise [Jist::Error]  if something went wrong
  # @see http://developer.github.com/v3/oauth/
  def login!
    puts "Obtaining OAuth2 access_token from github."
    print "Github username: "
    username = $stdin.gets.strip
    print "Github password: "
    password = begin
      `stty -echo` rescue nil
      $stdin.gets.strip
    ensure
      `stty echo` rescue nil
    end
    puts ""

    request = Net::HTTP::Post.new("#{base_path}/authorizations")
    request.body = JSON.dump({
      :scopes => [:gist],
      :note => "The jist gem",
      :note_url => "https://github.com/ConradIrwin/jist"
    })
    request.content_type = 'application/json'
    request.basic_auth(username, password)

    response = http(api_url, request)

    if Net::HTTPCreated === response
      File.open(auth_token_file, 'w') do |f|
        f.write JSON.parse(response.body)['token']
      end
      puts "Success! https://#{ENV["GITHUB_HOST"] || "github.com"}/settings/applications"
    else
      raise "Got #{response.class} from gist: #{response.body}"
    end
  rescue => e
    raise e.extend Error
  end

  # Return HTTP connection
  #
  # @param [URI::HTTP] The URI to which to connect
  # @return [Net::HTTP]
  def http_connection(uri)
    env = ENV['http_proxy'] || ENV['HTTP_PROXY']
    connection = if env
                   proxy = URI(env)
                   Net::HTTP::Proxy(proxy.host, proxy.port).new(uri.host, uri.port)
                 else
                   Net::HTTP.new(uri.host, uri.port)
                 end
    if uri.scheme == "https"
      connection.use_ssl = true
      connection.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    connection.open_timeout = 10
    connection.read_timeout = 10
    connection
  end

  # Run an HTTP operation
  #
  # @param [URI::HTTP] The URI to which to connect
  # @param [Net::HTTPRequest] The request to make
  # @return [Net::HTTPResponse]
  def http(url, request)
    http_connection(url).start do |http|
      http.request request
    end
  rescue Timeout::Error
    raise "Could not connect to https://api.github.com/"
  end

  # Called after an HTTP response to gist to perform post-processing.
  #
  # @param [String] body  the text body from the github api
  # @param [Hash] options  more detailed options, see
  #   the documentation for {multi_gist}
  def on_success(body, options={})
    json = JSON.parse(body)

    output = case options[:output]
             when :javascript
               %Q{<script src="#{json['html_url']}.js"></script>}
             when :html_url
               json['html_url']
             when :short_url
               shorten(json['html_url'])
             else
               json
             end

    Jist.copy(output.to_s) if options[:copy]
    Jist.open(json['html_url']) if options[:open]

    output
  end

  # Copy a string to the clipboard.
  #
  # @param [String] content
  # @raise [Jist::Error] if no clipboard integration could be found
  #
  def copy(content)
    IO.popen(clipboard_command(:copy), 'r+') { |clip| clip.print content }
    raise Error, 'Copying to clipboard failed.' unless paste == content
  rescue Error => e
    raise ClipboardError, e.message + "\nAttempted to copy: #{content}"
  end

  # Get a string from the clipboard.
  #
  # @param [String] content
  # @raise [Jist::Error] if no clipboard integration could be found
  def paste
    `#{clipboard_command(:paste)}`
  end

  # Find command from PATH environment.
  #
  # @param [String] cmd  command name to find
  # @param [String] options  PATH environment variable
  # @return [String]  the command found
  def which(cmd, path=ENV['PATH'])
    if RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin|cygwin/
      path.split(File::PATH_SEPARATOR).each {|dir|
        f = File.join(dir, cmd+".exe")
        return f if File.executable?(f) && !File.directory?(f)
      }
      nil
    else
      return system("which #{cmd} > /dev/null 2>&1")
    end
  end

  # Get the command to use for the clipboard action.
  #
  # @param [Symbol] action  either :copy or :paste
  # @return [String]  the command to run
  # @raise [Jist::ClipboardError] if no clipboard integration could be found
  def clipboard_command(action)
    command = CLIPBOARD_COMMANDS.keys.detect do |cmd|
      which cmd
    end
    raise ClipboardError, <<-EOT unless command
Could not find copy command, tried:
    #{CLIPBOARD_COMMANDS.values.join(' || ')}
    EOT
    action == :copy ? command : CLIPBOARD_COMMANDS[command]
  end

  # Open a URL in a browser.
  #
  # @param [String] url
  # @raise [RuntimeError] if no browser integration could be found
  #
  # This method was heavily inspired by defunkt's Gist#open,
  # @see https://github.com/defunkt/gist/blob/bca9b29/lib/gist.rb#L157
  def open(url)
    command = if ENV['BROWSER']
                ENV['BROWSER']
              elsif RUBY_PLATFORM =~ /darwin/
                'open'
              elsif RUBY_PLATFORM =~ /linux/
                %w(
                  sensible-browser
                  firefox
                  firefox-bin
                ).detect do |cmd|
                  which cmd
                end
              elsif ENV['OS'] == 'Windows_NT' || RUBY_PLATFORM =~ /djgpp|(cyg|ms|bcc)win|mingw|wince/i
                'start ""'
              else
                raise "Could not work out how to use a browser."
              end

    `#{command} #{url}`
  end

  # Get the API base path
  def base_path
    ENV.key?("GITHUB_HOST") ? GHE_BASE_PATH : GITHUB_BASE_PATH
  end

  # Get the API URL
  def api_url
    ENV.key?("GITHUB_HOST") ? URI("https://#{ENV["GITHUB_HOST"]}/") : GITHUB_API_URL
  end

  def auth_token_file
    if ENV.key?("GITHUB_HOST")
      File.expand_path "~/.jist.#{ENV["GITHUB_HOST"].gsub(/[^a-z.]/, '')}"
    else
      File.expand_path "~/.jist"
    end
  end
end
