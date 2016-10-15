require_relative "../../../test_helper"

class TestAdminStatsLogs < Minitest::Capybara::Test
  include ApiUmbrellaTests::AdminAuth
  include ApiUmbrellaTests::Setup

  def setup
    setup_server
    ElasticsearchHelper.clean_es_indices(["2014-11", "2015-01", "2015-03"])
  end

  def test_strips_api_keys_from_request_url_in_json
    FactoryGirl.create(:log_item, :request_at => Time.parse("2015-01-16T06:06:28.816Z").utc, :request_url => "http://127.0.0.1/with_api_key/?foo=bar&api_key=my_secret_key", :request_query => { "foo" => "bar", "api_key" => "my_secret_key" })
    LogItem.gateway.refresh_index!

    response = Typhoeus.get("https://127.0.0.1:9081/admin/stats/logs.json", @@http_options.deep_merge(admin_session).deep_merge({
      :params => {
        "tz" => "America/Denver",
        "start_at" => "2015-01-13",
        "end_at" => "2015-01-18",
        "interval" => "day",
        "start" => "0",
        "length" => "10",
      },
    }))

    assert_equal(200, response.code, response.body)
    body = response.body
    data = MultiJson.load(body)
    assert_equal(1, data["recordsTotal"])
    assert_equal("/with_api_key/?foo=bar", data["data"][0]["request_url"])
    assert_equal({ "foo" => "bar" }, data["data"][0]["request_query"])
    refute_match("my_secret_key", body)
  end

  def test_strips_api_keys_from_request_url_in_csv
    FactoryGirl.create(:log_item, :request_at => Time.parse("2015-01-16T06:06:28.816Z").utc, :request_url => "http://127.0.0.1/with_api_key/?api_key=my_secret_key&foo=bar", :request_query => { "foo" => "bar", "api_key" => "my_secret_key" })
    LogItem.gateway.refresh_index!

    response = Typhoeus.get("https://127.0.0.1:9081/admin/stats/logs.csv", @@http_options.deep_merge(admin_session).deep_merge({
      :params => {
        "tz" => "America/Denver",
        "start_at" => "2015-01-13",
        "end_at" => "2015-01-18",
        "interval" => "day",
        "start" => "0",
        "length" => "10",
      },
    }))

    assert_equal(200, response.code, response.body)
    body = response.body
    assert_match(",http://127.0.0.1/with_api_key/?foo=bar,", body)
    refute_match("my_secret_key", body)
  end

  def test_downloading_csv_that_uses_scan_and_scroll_elasticsearch_query
    FactoryGirl.create_list(:log_item, 1005, :request_at => Time.parse("2015-01-16T06:06:28.816Z").utc)
    LogItem.gateway.refresh_index!

    response = Typhoeus.get("https://127.0.0.1:9081/admin/stats/logs.csv", @@http_options.deep_merge(admin_session).deep_merge({
      :params => {
        "tz" => "America/Denver",
        "search" => "",
        "start_at" => "2015-01-13",
        "end_at" => "2015-01-18",
        "interval" => "day",
      },
    }))

    assert_equal(200, response.code, response.body)
    assert_equal("text/csv", response.headers["Content-Type"])
    assert_match("attachment; filename=\"api_logs (#{Time.now.utc.strftime("%b %-e %Y")}).csv\"", response.headers["Content-Disposition"])

    lines = response.body.split("\n")
    assert_equal("Time,Method,Host,URL,User,IP Address,Country,State,City,Status,Reason Denied,Response Time,Content Type,Accept Encoding,User Agent", lines[0])
    assert_equal(1006, lines.length)
  end

  def test_query_builder_case_insensitive_defaults
    FactoryGirl.create(:log_item, :request_at => Time.parse("2015-01-16T06:06:28.816Z").utc, :request_user_agent => "MOZILLAAA")
    LogItem.gateway.refresh_index!

    response = Typhoeus.get("https://127.0.0.1:9081/admin/stats/logs.json", @@http_options.deep_merge(admin_session).deep_merge({
      :params => {
        "tz" => "America/Denver",
        "start_at" => "2015-01-13",
        "end_at" => "2015-01-18",
        "interval" => "day",
        "start" => "0",
        "length" => "10",
        "query" => '{"condition":"AND","rules":[{"id":"request_user_agent","field":"request_user_agent","type":"string","input":"text","operator":"begins_with","value":"Mozilla"}]}',
      },
    }))

    assert_equal(200, response.code, response.body)
    data = MultiJson.load(response.body)
    assert_equal(1, data["recordsTotal"])
    assert_equal("MOZILLAAA", data["data"][0]["request_user_agent"])
  end

  def test_query_builder_api_key_case_sensitive
    FactoryGirl.create(:log_item, :request_at => Time.parse("2015-01-16T06:06:28.816Z").utc, :api_key => "AbCDeF", :request_user_agent => "api key match test")
    LogItem.gateway.refresh_index!

    response = Typhoeus.get("https://127.0.0.1:9081/admin/stats/logs.json", @@http_options.deep_merge(admin_session).deep_merge({
      :params => {
        "tz" => "America/Denver",
        "start_at" => "2015-01-13",
        "end_at" => "2015-01-18",
        "interval" => "day",
        "start" => "0",
        "length" => "10",
        "query" => '{"condition":"AND","rules":[{"id":"api_key","field":"api_key","type":"string","input":"text","operator":"begins_with","value":"AbCDeF"}]}',
      },
    }))

    assert_equal(200, response.code, response.body)
    data = MultiJson.load(response.body)
    assert_equal(1, data["recordsTotal"])
    assert_equal("api key match test", data["data"][0]["request_user_agent"])
  end

  def test_query_builder_nulls
    FactoryGirl.create(:log_item, :request_at => Time.parse("2015-01-16T06:06:28.816Z").utc, :request_user_agent => "gatekeeper denied code null test")
    FactoryGirl.create(:log_item, :request_at => Time.parse("2015-01-16T06:06:28.816Z").utc, :gatekeeper_denied_code => "api_key_missing", :request_user_agent => "gatekeeper denied code not null test")
    LogItem.gateway.refresh_index!

    response = Typhoeus.get("https://127.0.0.1:9081/admin/stats/logs.json", @@http_options.deep_merge(admin_session).deep_merge({
      :params => {
        "tz" => "America/Denver",
        "start_at" => "2015-01-13",
        "end_at" => "2015-01-18",
        "interval" => "day",
        "start" => "0",
        "length" => "10",
        "query" => '{"condition":"AND","rules":[{"id":"gatekeeper_denied_code","field":"gatekeeper_denied_code","type":"string","input":"select","operator":"is_not_null","value":null}]}',
      },
    }))

    assert_equal(200, response.code, response.body)
    data = MultiJson.load(response.body)
    assert_equal(1, data["recordsTotal"])
    assert_equal("gatekeeper denied code not null test", data["data"][0]["request_user_agent"])
  end
end