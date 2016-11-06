require_relative "../test_helper"

class TestProxyHttpsRequirements < Minitest::Test
  include ApiUmbrellaTests::Setup
  include Minitest::Hooks

  def setup
    setup_server
    once_per_class_setup do
      # Restore the real global default setting for "require_https" (as defined
      # in config/default.yml). This is needed since we override the default
      # value in the test environment (config/test.yml) to be "optional" so
      # that most of our test suite can use just http, which is sometimes
      # easier to debug.
      override_config_set({
        "apiSettings" => {
          "require_https" => "required_return_error",
        },
      }, "--router")

      prepend_api_backends([
        {
          :frontend_host => "127.0.0.1",
          :backend_host => "127.0.0.1",
          :servers => [{ :host => "127.0.0.1", :port => 9444 }],
          :url_matches => [{ :frontend_prefix => "/#{unique_test_class_id}/default/", :backend_prefix => "/" }],
        },
        {
          :frontend_host => "127.0.0.1",
          :backend_host => "127.0.0.1",
          :servers => [{ :host => "127.0.0.1", :port => 9444 }],
          :url_matches => [{ :frontend_prefix => "/#{unique_test_class_id}/required_return_error/", :backend_prefix => "/" }],
          :settings => {
            :require_https => "required_return_error",
          },
        },
        {
          :frontend_host => "127.0.0.1",
          :backend_host => "127.0.0.1",
          :servers => [{ :host => "127.0.0.1", :port => 9444 }],
          :url_matches => [{ :frontend_prefix => "/#{unique_test_class_id}/transition_return_error/", :backend_prefix => "/" }],
          :settings => {
            :require_https => "transition_return_error",
            :require_https_transition_start_at => Time.iso8601("2013-01-01T01:27:00Z"),
          },
        },
        {
          :frontend_host => "127.0.0.1",
          :backend_host => "127.0.0.1",
          :servers => [{ :host => "127.0.0.1", :port => 9444 }],
          :url_matches => [{ :frontend_prefix => "/#{unique_test_class_id}/optional/", :backend_prefix => "/" }],
          :settings => {
            :require_https => "optional",
          },
          :sub_settings => [
            {
              :http_method => "any",
              :regex => "^/hello/sub-inherit/",
              :settings => {
                :require_https => nil,
              },
            },
            {
              :http_method => "any",
              :regex => "^/hello/sub-required/",
              :settings => {
                :require_https => "required_return_error",
              },
            },
          ],
        },
      ])
    end
  end

  def after_all
    super
    override_config_reset("--router")
  end

  def test_default_required_return_error
    assert_https_allowed("/#{unique_test_class_id}/default/hello")
    assert_http_error("/#{unique_test_class_id}/default/hello")
  end

  def test_required_return_error
    assert_https_allowed("/#{unique_test_class_id}/required_return_error/hello")
    assert_http_error("/#{unique_test_class_id}/required_return_error/hello")
  end

  def transition_return_error_user_created_before_transition_time
    user = FactoryGirl.create(:api_user, :created_at => Time.iso8601("2013-01-01T01:26:59Z"))
    assert_https_allowed("/#{unique_test_class_id}/transition_return_error/hello", user.api_key)
    assert_http_allowed("/#{unique_test_class_id}/transition_return_error/hello", user.api_key)
  end

  def transition_return_error_user_created_after_transition_time
    user = FactoryGirl.create(:api_user, :created_at => Time.iso8601("2013-01-01T01:27:00Z"))
    assert_https_allowed("/#{unique_test_class_id}/transition_return_error/hello", user.api_key)
    assert_http_error("/#{unique_test_class_id}/transition_return_error/hello", user.api_key)
  end

  def test_optional
    assert_https_allowed("/#{unique_test_class_id}/optional/hello")
    assert_http_allowed("/#{unique_test_class_id}/optional/hello")
  end

  def test_sub_url_settings_inherits_parent_settings
    assert_https_allowed("/#{unique_test_class_id}/optional/hello/sub-inherit/")
    assert_http_allowed("/#{unique_test_class_id}/optional/hello/sub-inherit/")
  end

  def test_sub_url_settings_overrides_parent_settings
    assert_https_allowed("/#{unique_test_class_id}/optional/hello/sub-required/")
    assert_http_error("/#{unique_test_class_id}/optional/hello/sub-required/")
  end

  def test_https_url_with_host_in_error_message
    prepend_api_backends([
      {
        :frontend_host => "https.foo",
        :backend_host => "127.0.0.1",
        :servers => [{ :host => "127.0.0.1", :port => 9444 }],
        :url_matches => [{ :frontend_prefix => "/#{unique_test_id}/required/", :backend_prefix => "/" }],
        :settings => {
          :require_https => "required_return_error",
        },
      },
    ]) do
      response = Typhoeus.get("http://127.0.0.1:9080/#{unique_test_id}/required/hello/?foo=bar&test1=test2", self.http_options.deep_merge({
        :headers => {
          "Host" => "https.foo",
        },
      }))
      assert_equal(400, response.code, response.body)
      assert_match("HTTPS_REQUIRED", response.body)
      assert_match("https://https.foo:9081/#{unique_test_id}/required/hello/?foo=bar&test1=test2", response.body)
    end
  end

  private

  def assert_https_allowed(path, key = nil)
    response = Typhoeus.get("https://127.0.0.1:9081#{path}", self.http_options.deep_merge({
      :headers => {
        "X-Api-Key" => key || self.api_key,
      },
    }))
    assert_equal(200, response.code, response.body)
  end

  def assert_http_allowed(path, key = nil)
    response = Typhoeus.get("http://127.0.0.1:9080#{path}", self.http_options.deep_merge({
      :headers => {
        "X-Api-Key" => key || self.api_key,
      },
    }))

    assert_equal(200, response.code, response.body)
  end

  def assert_http_error(path, key = nil)
    response = Typhoeus.get("http://127.0.0.1:9080#{path}", self.http_options.deep_merge({
      :headers => {
        "X-Api-Key" => key || self.api_key,
      },
    }))
    assert_equal(400, response.code, response.body)
    assert_match("HTTPS_REQUIRED", response.body)
    assert_match("https://127.0.0.1:9081#{path}", response.body)
  end
end