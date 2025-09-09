require "test_helper"

class FeedFilters::PreParse::AtomNamespaceFixerTest < ActiveSupport::TestCase
  setup do
    @filter = FeedFilters::PreParse::AtomNamespaceFixer.new
  end

  test "detects Atom feed with https namespace (double quotes)" do
    xml = '<?xml version="1.0"?><feed xmlns="https://www.w3.org/2005/Atom">'
    assert @filter.applicable?(xml, {})
  end

  test "detects Atom feed with https namespace (single quotes)" do
    xml = "<?xml version='1.0'?><feed xmlns='https://www.w3.org/2005/Atom'>"
    assert @filter.applicable?(xml, {})
  end

  test "does not detect Atom feed with correct http namespace" do
    xml = '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">'
    assert_not @filter.applicable?(xml, {})
  end

  test "does not detect RSS feed" do
    xml = '<?xml version="1.0"?><rss version="2.0">'
    assert_not @filter.applicable?(xml, {})
  end

  test "fixes Atom namespace from https to http (double quotes)" do
    xml = '<?xml version="1.0"?><feed xmlns="https://www.w3.org/2005/Atom"><title>Test</title></feed>'
    expected = '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Test</title></feed>'

    result = @filter.apply(xml, {})

    assert_equal expected, result
    assert @filter.applied
    assert_equal "Atom namespace URL protocol", @filter.details[:fixed]
  end

  test "fixes Atom namespace from https to http (single quotes)" do
    xml = "<?xml version='1.0'?><feed xmlns='https://www.w3.org/2005/Atom'><title>Test</title></feed>"
    expected = "<?xml version='1.0'?><feed xmlns='http://www.w3.org/2005/Atom'><title>Test</title></feed>"

    result = @filter.apply(xml, {})

    assert_equal expected, result
    assert @filter.applied
    assert_equal "Atom namespace URL protocol", @filter.details[:fixed]
  end

  test "does not modify XML without https namespace" do
    xml = '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Test</title></feed>'

    result = @filter.apply(xml, {})

    assert_equal xml, result
    assert_not @filter.applied
  end

  test "handles multiple occurrences of namespace declaration" do
    xml = '<feed xmlns="https://www.w3.org/2005/Atom"><entry xmlns="https://www.w3.org/2005/Atom"></entry></feed>'
    expected = '<feed xmlns="http://www.w3.org/2005/Atom"><entry xmlns="http://www.w3.org/2005/Atom"></entry></feed>'

    result = @filter.apply(xml, {})

    assert_equal expected, result
    assert @filter.applied
  end
end
