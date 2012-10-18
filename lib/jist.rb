require 'net/https'
require 'cgi'
require 'json'

# It just gists.
module Jist
  extend self

  VERSION = '1.0.1'

  # A list of clipboard commands with copy and paste support.
  CLIPBOARD_COMMANDS = {
    'xclip'   => 'xclip -o',
    'xsel'    => 'xsel -o',
    'pbcopy'  => 'pbpaste',
    'putclip' => 'getclip'
  }

  # Exception tag for errors raised while gisting.
  module Error; end

  # Upload a gist to https://gist.github.com
  #
  # @param [String] content  the code you'd like to gist
  # @param [Hash] options  more detailed options
  #
  # @option options [String] :description  the description
  # @option options [String] :filename  ('a.rb') the filename
  # @option options [Boolean] :public  (false) is this gist public
  # @option options [Boolean] :anonymous  (false) is this gist anonymous
  # @option options [String] :access_token  (`File.read("~/.jist")`) The OAuth2 access token.
  # @option options [String] :update  the URL or id of a gist to update
  # @option options [Boolean] :copy  (false) Copy resulting URL to clipboard, if successful.
  # @option options [Boolean] :open  (false) Open the resulting URL in a browser.
  #
  # @return [Hash]  the decoded JSON response from the server
  # @raise [Jist::Error]  if something went wrong
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
  #
  # @return [Hash]  the decoded JSON response from the server
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
      access_token = (options[:access_token] || File.read(File.expand_path("~/.jist")) rescue nil)
    end

    url = "/gists"
    url << "/" << CGI.escape(existing_gist) if existing_gist.to_s != ''
    url << "?access_token=" << CGI.escape(access_token) if access_token.to_s != ''

    request = Net::HTTP::Post.new(url)
    request.body = JSON.dump(json)
    request.content_type = 'application/json'

    retried = false

    begin
      response = http(request)
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

    request = Net::HTTP::Post.new("/authorizations")
    request.body = JSON.dump({
      :scopes => [:gist],
      :note => "The jist gem",
      :note_url => "https://github.com/ConradIrwin/jist"
    })
    request.content_type = 'application/json'
    request.basic_auth(username, password)

    response = http(request)

    if Net::HTTPCreated === response
      File.open(File.expand_path("~/.jist"), 'w') do |f|
        f.write JSON.parse(response.body)['token']
      end
      puts "Success! https://github.com/settings/applications"
    else
      raise "Got #{response.class} from gist: #{response.body}"
    end
  rescue => e
    raise e.extend Error
  end

  # Return HTTP connection
  #
  # @return [Net::HTTP]
  def http_connection()
    env = ENV['http_proxy']
    if env then
      uri = URI(env)
      proxy_host, proxy_port = uri.host, uri.port
    else
      proxy_host, proxy_port = nil, nil
    end
    connection = Net::HTTP::Proxy(proxy_host, proxy_port).new("api.github.com", 443)
    connection.use_ssl = true
    connection.verify_mode = OpenSSL::SSL::VERIFY_NONE
    connection.open_timeout = 10
    connection.read_timeout = 10
    connection
  end

  # Run an HTTP operation against api.github.com
  #
  # @param [Net::HTTPRequest] request
  # @return [Net::HTTPResponse]
  def http(request)
    http_connection().start do |http|
      http.request request
    end
  rescue Timeout::Error
    raise "Could not connect to https://api.github.com/"
  end

  # Called after an HTTP response to gist to perform post-processing.
  #
  # @param [String] body  the HTTP-200 response
  # @param [Hash] options  any options
  # @option options [Boolean] :copy  copy the URL to the clipboard
  # @return [Hash]  the parsed JSON response from the server
  def on_success(body, options={})
    json = JSON.parse(body)

    Jist.copy(json['html_url']) if options[:copy]
    Jist.open(json['html_url']) if options[:open]

    json
  end

  # Copy a string to the clipboard.
  #
  # @param [String] content
  # @raise [RuntimeError] if no clipboard integration could be found
  #
  # This method was heavily inspired by defunkt's Gist#copy,
  # @see https://github.com/defunkt/gist/blob/bca9b29/lib/gist.rb#L178
  def copy(content)
    IO.popen(clipboard_command(:copy), 'r+') { |clip| clip.print content }
    raise "Copying to clipboard failed" unless paste == content
  end

  # Get a string from the clipboard.
  #
  # @param [String] content
  # @raise [RuntimeError] if no clipboard integration could be found
  def paste
    `#{clipboard_command(:paste)}`
  end

  # Get the command to use for the clipboard action.
  #
  # @param [Symbol] action  either :copy or :paste
  # @return [String]  the command to run
  # @raise [RuntimeError] if no clipboard integration could be found
  def clipboard_command(action)
    command = CLIPBOARD_COMMANDS.keys.detect do |cmd|
      system("type #{cmd} >/dev/null 2>&1")
    end
    raise "Could not find copy command, tried: #{CLIPBOARD_COMMANDS}" unless command
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
                'sensible-browser'
              elsif ENV['OS'] == 'Windows_NT' || RUBY_PLATFORM =~ /djgpp|(cyg|ms|bcc)win|mingw|wince/i
                'start ""'
              else
                raise "Could not work out how to use a browser."
              end

    `#{command} #{url}`
  end
end
