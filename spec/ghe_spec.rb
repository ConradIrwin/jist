describe '...' do

  MOCK_GHE_HOST = 'ghe.example.com'
  MOCK_USER = 'foo'
  MOCK_PASSWORD = 'bar'
  MOCK_AUTHZ_GHE_URL = "http://#{MOCK_USER}:#{MOCK_PASSWORD}@#{MOCK_GHE_HOST}/"
  MOCK_GHE_URL = "http://#{MOCK_GHE_HOST}/"

  before do
    @saved_env = ENV['GITHUB_HOST']

    # stub requests for /gists
    stub_request(:post, /^https:\/\/#{MOCK_GHE_HOST}\/api\/v3\/gists/).to_return(:body => %[{"html_url": "http://#{MOCK_GHE_HOST}"}])
    stub_request(:post, /^https:\/\/api.github.com\/gists/).to_return(:body => '{"html_url": "http://github.com/"}')

    # stub requests for /authorizations
    stub_request(:post, /^https:\/\/#{MOCK_USER}:#{MOCK_PASSWORD}@#{MOCK_GHE_HOST}\/api\/v3\/authorizations/).
      to_return(:status => 201, :body => '{"token": "asdf"}')
    stub_request(:post, /^https:\/\/#{MOCK_USER}:#{MOCK_PASSWORD}@api.github.com\/authorizations/).
      to_return(:status => 201, :body => '{"token": "asdf"}')
  end

  after do
    ENV['GITHUB_HOST'] = @saved_env
  end

  describe :login! do
    before do
      @saved_stdin = $stdin

      # stdin emulation
      $stdin = StringIO.new "#{MOCK_USER}\n#{MOCK_PASSWORD}\n"

      # intercept for updating ~/.jist
      File.stub(:open)
    end

    after do
      $stdin = @saved_stdin
    end

    it "should access to api.github.com when $GITHUB_HOST wasn't set" do
      ENV.delete 'GITHUB_HOST'
      Jist.login!
      assert_requested(:post, /api.github.com\/authorizations/)
    end

    it "should access to #{MOCK_GHE_HOST} when $GITHUB_HOST was set" do
      ENV['GITHUB_HOST'] = MOCK_GHE_HOST
      Jist.login!
      assert_requested(:post, /#{MOCK_GHE_HOST}\/api\/v3\/authorizations/)
    end
  end

  describe :gist do
    it "should access to api.github.com when $GITHUB_HOST wasn't set" do
      ENV.delete 'GITHUB_HOST'
      Jist.gist "test gist"
      assert_requested(:post, /api.github.com\/gists/)
    end

    it "should access to #{MOCK_GHE_HOST} when $GITHUB_HOST was set" do
      ENV['GITHUB_HOST'] = MOCK_GHE_HOST
      Jist.gist "test gist"
      assert_requested(:post, /#{MOCK_GHE_HOST}\/api\/v3\/gists/)
    end
  end
end
